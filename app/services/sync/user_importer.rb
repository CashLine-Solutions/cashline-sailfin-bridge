module Sync
  # Imports Sailfin `User` rows into the platform `users` table so downstream
  # importers (Tasks, Communications, …) can attribute work to real people —
  # including the ~half of Sailfin users who have already left CashLine. They're
  # kept purely for historical reference ("on 2025-05-01, X did Y") with NO login.
  #
  # This importer is deliberately UNLIKE the account/contact/invoice importers:
  #
  #   - NOT operator-scoped and NOT purge-and-rebuild. `users` is a global Devise
  #     table keyed by a UNIQUE sailfin_user_id; a row may later be granted a real
  #     login (password + invitation + unblocked). Purging would delete live
  #     accounts. So it's insert-mostly and found-or-create, like the scaffolding.
  #
  #   - NON-DESTRUCTIVE to auth state. We set `blocked` + a placeholder password
  #     ONLY when first creating a row. On re-sync we refresh display fields
  #     (first/last name) and never touch blocked / encrypted_password /
  #     invitation state — so a person invited in the platform AFTER import is
  #     never silently re-blocked or re-passworded on the next sync.
  #
  # Every imported user is `blocked: true` (User#active_for_authentication? is
  # `super && !blocked?`, so blocked == cannot log in). Granting access is a
  # separate, deliberate platform invitation step, out of scope for the sync.
  #
  # All Sailfin users are imported, including the handful of system/automation
  # accounts (AutomatedProcess, CloudIntegrationUser, …), so Task.OwnerId /
  # CreatedById never dangle.
  #
  # email is NOT NULL + UNIQUE on the platform. We match an incoming user to an
  # existing row by sailfin_user_id first, then by email — so a Sailfin user
  # whose email already belongs to an invited platform user updates that row (and
  # stamps its sailfin_user_id) instead of violating the unique index.
  class UserImporter
    OBJECT = "User".freeze
    # Devise requires encrypted_password (NOT NULL). A blank string is not a valid
    # bcrypt hash, so it can never authenticate — exactly right for a history-only
    # user. The platform invite flow replaces it when a real login is granted.
    NO_LOGIN_PASSWORD = "".freeze
    DEFAULT_THEME = "system".freeze

    def initialize(extraction_run_id:, limit: nil, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @scaffolding = scaffolding # unused today; kept for importer-signature parity
      @stats = Hash.new(0)
    end

    def call
      # Existing platform rows we must not clobber, indexed both ways.
      by_sailfin = CashlineSync::User.where.not(sailfin_user_id: nil)
                                     .pluck(:sailfin_user_id, :id).to_h
      by_email   = CashlineSync::User.pluck(:email, :id)
                                     .each_with_object({}) { |(e, id), h| h[normalize_email(e)] = id }
      seen_sids   = Set.new   # within-run dedup (Sailfin can repeat an email)
      seen_emails = Set.new
      inserts = []

      CashlineSync::User.transaction do
        scope.find_each do |rec|
          p = rec.payload
          sid = p["Id"]
          email = normalize_email(p["Email"])
          if email.blank?
            @stats[:skipped_no_email] += 1
            next
          end

          if (existing_id = by_sailfin[sid] || by_email[email])
            refresh_display(existing_id, p, sid)
            @stats[:updated] += 1
            next
          end

          if seen_sids.include?(sid) || seen_emails.include?(email)
            @stats[:skipped_duplicate_in_run] += 1
            next
          end
          seen_sids << sid
          seen_emails << email
          inserts << insert_row(p, sid, email)
        end

        CashlineSync::User.insert_all(inserts) if inserts.any?
      end

      @stats[:created] = inserts.size
      @stats[:sailfin_users] = @stats[:created] + @stats[:updated]
      @stats
    end

    private

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
      @limit ? s.limit(@limit) : s
    end

    # Refresh display fields only — never auth state. Stamp sailfin_user_id only
    # when the matched row doesn't already carry one (i.e. we matched an invited
    # platform user by email), so we never steal an id from another Sailfin user.
    def refresh_display(id, p, sid)
      now = Time.current
      CashlineSync::User.where(id: id)
                        .update_all(first_name: first_name(p), last_name: last_name(p), updated_at: now)
      CashlineSync::User.where(id: id, sailfin_user_id: nil).update_all(sailfin_user_id: sid)
    end

    def insert_row(p, sid, email)
      now = Time.current
      {
        email: email,
        first_name: first_name(p),
        last_name: last_name(p),
        sailfin_user_id: sid,
        blocked: true,                       # history-only: no login
        encrypted_password: NO_LOGIN_PASSWORD,
        theme_preference: DEFAULT_THEME,
        created_at: now,
        updated_at: now
      }
    end

    # FirstName is ~99% filled; fall back to the first token of Name, else blank
    # (the column is NOT NULL; User#display_name falls back to email anyway).
    def first_name(p)
      p["FirstName"].presence || p["Name"].to_s.split(/\s+/).first.presence || ""
    end

    def last_name(p)
      p["LastName"].presence || ""
    end

    def normalize_email(email)
      email.to_s.strip.downcase.presence
    end
  end
end
