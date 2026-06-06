module Sync
  # Detects candidate parent-customer groupings from Sailfin Account data, for an
  # operator to confirm/reject before the importer applies them.
  #
  # The flat Sailfin `Account.Name` often encodes a parent + location, e.g.
  # "BREITBURN OPERATING - GAYLORD" / "BREITBURN OPERATING - HOUSTON". These
  # should roll up under one Customer::Organization, but the relationship is
  # frequently only in the name (the structural ParentId/Parent_No__c fields are
  # sparse — see docs/method/questions-for-dre-bryce.md Q6). So detection is
  # deterministic and conservative here; an LLM-assisted pass for ambiguous cases
  # is a later layer, always feeding the same human review queue.
  #
  # Signals, cheapest/most-trustworthy first:
  #   1. structural_parent_no — Accounts sharing a non-blank Parent_No__c
  #   2. name_prefix          — Accounts sharing the text before the first " - "
  #
  # An account is claimed by at most one grouping per run (structural wins over
  # name). Detection is idempotent: a grouping already confirmed/rejected by an
  # operator keeps its state; we only refresh membership and add new candidates.
  class CustomerGroupingDetector
    OBJECT = "Account".freeze
    DELIMITER = " - ".freeze
    MIN_MEMBERS = 2

    Candidate = Struct.new(:parent_name, :method, :members, keyword_init: true)

    def initialize(extraction_run)
      @run = extraction_run
      @claimed = {}   # sailfin_account_id => true (one grouping per account per run)
      @stats = Hash.new(0)
    end

    def self.call(extraction_run)
      new(extraction_run).call
    end

    def call
      accounts = load_accounts
      @stats[:accounts_scanned] = accounts.size

      candidates = []
      candidates.concat(structural_candidates(accounts))
      candidates.concat(name_candidates(accounts))

      # Fold each candidate into its canonical bucket, applying operator merges
      # (aliases). Two candidates can land in the same bucket (e.g. "CBRE" and
      # the alias "CB RICHARD ELLIS"), so we aggregate members per canonical name
      # before persisting — a single sync per grouping avoids members from one
      # candidate clobbering another's.
      aliases = CustomerGroupingAlias.map_for(@run.id)
      buckets = {}   # canonical_display_name => { method:, members: [{..., source_parent_name:}] }
      candidates.each do |c|
        canonical = aliases[normalize(c.parent_name)] || c.parent_name
        bucket = (buckets[canonical] ||= { method: c.method, members: [] })
        c.members.each { |m| bucket[:members] << m.merge(source_parent_name: c.parent_name) }
      end

      @persisted_ids = []
      buckets.each { |name, data| persist(name, data[:method], data[:members]) }

      # Drop open groupings this run no longer produces (e.g. detection logic
      # changed, or accounts were renamed). Confirmed/rejected groupings are an
      # operator's record and are left alone even if they go stale.
      stale = CustomerGrouping.for_run(@run.id).open.where.not(id: @persisted_ids)
      @stats[:groupings_pruned] = stale.count
      stale.destroy_all

      @stats
    end

    private

    # [{ id:, name:, parent_no: }, ...]
    def load_accounts
      SfRecord
        .where(extraction_run_id: @run.id, object_api_name: OBJECT)
        .pluck(
          Arel.sql("payload->>'Id'"),
          Arel.sql("payload->>'Name'"),
          Arel.sql("payload->>'Parent_No__c'")
        )
        .filter_map do |id, name, parent_no|
          next if id.blank? || name.blank?
          { id: id, name: name.strip, parent_no: parent_no.presence }
        end
    end

    # Accounts sharing a non-blank Parent_No__c are the same payer/parent.
    def structural_candidates(accounts)
      groups = accounts.group_by { |a| a[:parent_no] }
      groups.filter_map do |parent_no, members|
        next if parent_no.nil? || members.size < MIN_MEMBERS

        members.each { |m| @claimed[m[:id]] = true }
        Candidate.new(
          parent_name: common_prefix_label(members) || "Parent ##{parent_no}",
          method: "structural_parent_no",
          members: members
        )
      end
    end

    # Group accounts by a normalized "entity key" derived from their parent label
    # (the text before the first " - ", or the whole name if there's no
    # delimiter). The entity key collapses noise that splits the same customer:
    # trailing punctuation ("DALLAS, CITY OF," == "DALLAS, CITY OF"), internal
    # periods ("C.B." == "CB"), case, and trailing legal suffixes ("CBRE, INC."
    # == "CBRE"). So location variants AND punctuation/suffix variants land in one
    # bucket without a delimiter being required. Rebrands (CB RICHARD ELLIS ==
    # CBRE) still need a manual merge — no string rule catches those.
    def name_candidates(accounts)
      buckets = Hash.new { |h, k| h[k] = [] }
      accounts.each do |a|
        next if @claimed[a[:id]]

        label = a[:name].include?(DELIMITER) ? a[:name].split(DELIMITER, 2).first.strip : a[:name].strip
        key = entity_key(label)
        next if key.blank?

        buckets[key] << a.merge(parent_label: label)
      end

      buckets.filter_map do |_key, members|
        next if members.size < MIN_MEMBERS

        members.each { |m| @claimed[m[:id]] = true }
        Candidate.new(
          parent_name: most_common_label(members),
          method: method_for(members),
          members: members
        )
      end
    end

    # Idempotent upsert: preserve operator-set state, refresh members + confidence.
    def persist(parent_name, method, members)
      grouping = CustomerGrouping.find_or_initialize_by(
        extraction_run_id: @run.id,
        parent_name: parent_name
      )
      new_record = grouping.new_record?
      grouping.detection_method = method
      grouping.confidence = confidence_for(parent_name, method, members)
      # Auto-confirm true duplicates on first sight; everything else waits for an
      # operator. Never touch the state of an existing grouping (an operator may
      # have already confirmed/rejected/merged it).
      if new_record
        grouping.state = AUTO_CONFIRM_METHODS.include?(method) ? "confirmed" : "open"
        grouping.user_modified = false   # distinguishes auto-confirmed from operator-confirmed
      end
      grouping.state ||= "open"
      grouping.save!
      @persisted_ids << grouping.id
      @stats[:auto_confirmed] += 1 if new_record && grouping.state == "confirmed"

      sync_members(grouping, members)

      @stats[new_record ? :groupings_created : :groupings_updated] += 1
      @stats[:members] += members.size
    end

    def sync_members(grouping, members)
      want = members.index_by { |m| m[:id] }
      have = grouping.members.index_by(&:sailfin_account_id)

      # Bulk insert new members — these run over the whole dataset (100k+ rows),
      # so per-row create! is far too slow.
      to_add = (want.keys - have.keys)
      unless to_add.empty?
        now = Time.current
        rows = to_add.map do |id|
          {
            customer_grouping_id: grouping.id,
            sailfin_account_id: id,
            account_name: want[id][:name],
            source_parent_name: want[id][:source_parent_name],
            created_at: now, updated_at: now
          }
        end
        CustomerGroupingMember.insert_all(rows)
      end

      # Keep provenance fresh for members that stayed (an alias may have changed
      # which candidate now feeds them).
      (want.keys & have.keys).each do |id|
        have[id].update!(source_parent_name: want[id][:source_parent_name]) if have[id].source_parent_name != want[id][:source_parent_name]
      end
      # Drop members that no longer match (e.g. account renamed out of the prefix).
      (have.keys - want.keys).each { |id| have[id].destroy }
    end

    # Confidence: exact dups and structural matches are trustworthy; otherwise
    # more members = stronger, and code-like parent labels are weaker.
    def confidence_for(parent_name, method, members)
      return "high" if method == "exact_duplicate"

      level = members.size >= 3 ? "high" : "medium"
      level = downgrade(level) if code_like?(parent_name)
      level = "high" if method == "structural_parent_no" && level != "low"
      level
    end

    def downgrade(level)
      { "high" => "medium", "medium" => "low", "low" => "low" }[level]
    end

    # 3+ consecutive digits suggests an internal code (e.g. "RAL25008-130-...")
    # rather than a clean company name — flag it for closer human review.
    def code_like?(label)
      label.match?(/\d{3,}/)
    end

    # Classify a name bucket:
    #   exact_duplicate — every member is the SAME name modulo punctuation/case
    #                     (no location suffix). These are true dup account rows;
    #                     safe to auto-confirm without human review.
    #   name_prefix     — at least one member had a " - " location suffix
    #                     (a roll-up judgment: one customer, many sites).
    #   normalized_name — merged only after stripping a legal suffix (CBRE, INC.
    #                     == CBRE) — a judgment call, kept for review.
    def method_for(members)
      return "name_prefix" if members.any? { |m| m[:name].include?(DELIMITER) }
      return "exact_duplicate" if members.map { |m| tight_key(m[:parent_label]) }.uniq.size == 1

      "normalized_name"
    end

    AUTO_CONFIRM_METHODS = %w[exact_duplicate].freeze

    # Pick the cleanest representative label: most frequent, tie-broken by the one
    # closest to its own entity key (i.e. least decoration), then shortest.
    def most_common_label(members)
      tally = members.map { |m| m[:parent_label] }.tally
      max = tally.values.max
      tally.select { |_l, n| n == max }.keys
           .min_by { |l| [ entity_key(l) == normalize(l) ? 0 : 1, l.length ] }
    end

    def common_prefix_label(members)
      with_delim = members.map { |m| m[:name] }.select { |n| n.include?(DELIMITER) }
      return nil if with_delim.empty?

      with_delim.map { |n| n.split(DELIMITER, 2).first.strip }
                .tally.max_by { |_p, n| n }.first
    end

    # Legal-entity suffix tokens stripped from the tail of an entity key so
    # "CBRE, INC." and "CBRE" collapse. Conservative: only trailing tokens, and
    # never the whole label (keeps single-word names like "INC" intact).
    STOP_SUFFIXES = %w[inc incorporated llc llp lp ltd limited co corp corporation company].freeze

    # Normalized identity key: delete periods (C.B. -> CB), turn other
    # punctuation into spaces (handles trailing commas), squish, then strip
    # trailing legal-suffix tokens.
    def entity_key(label)
      s = label.to_s.downcase.delete(".")
      s = s.gsub(/[^a-z0-9& ]/, " ").squish
      tokens = s.split(" ")
      tokens.pop while tokens.size > 1 && STOP_SUFFIXES.include?(tokens.last)
      tokens.join(" ")
    end

    # Like entity_key but WITHOUT legal-suffix stripping: two labels share a
    # tight key only if they're the same name modulo punctuation/whitespace/case.
    # Used to tell true duplicates (auto-confirm) from suffix-stripped merges.
    def tight_key(label)
      label.to_s.downcase.delete(".").gsub(/[^a-z0-9& ]/, " ").squish
    end

    # Alias matching works on the display parent label (squish/downcase), a layer
    # above entity_key — operators merge labels, the detector buckets by identity.
    def normalize(str)
      str.to_s.squish.downcase
    end
  end
end
