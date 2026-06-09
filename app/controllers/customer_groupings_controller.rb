# Review queue for candidate customer groupings (parent roll-ups detected from
# Sailfin Account names/structure). Confirm/reject mirrors mapping_proposals;
# the operator's decision persists and survives re-detection.
class CustomerGroupingsController < ApplicationController
  RENDER_LIMIT = 300

  before_action :load_run
  before_action :load_grouping, only: [ :confirm, :reject, :unreject, :merge, :unmerge, :unroll, :group_label ]
  after_action :verify_authorized

  def index
    if @run.nil?
      authorize CustomerGrouping, :index?
      @groupings = []
      return
    end
    authorize CustomerGrouping, :index?

    @state = CustomerGrouping::STATES.include?(params[:state]) ? params[:state] : "open"
    scoped = policy_scope(CustomerGrouping).for_run(@run.id).where(state: @state)
    # Name search — the queue runs to thousands and RENDER_LIMIT only shows the
    # first slice, so without this most groupings are unreachable in the UI.
    @q = params[:q].to_s.strip
    if @q.present?
      scoped = scoped.where("parent_name ILIKE ?", "%#{CustomerGrouping.sanitize_sql_like(@q)}%")
    end
    @total_in_state = scoped.count
    # Auto-confirmed exact dups can number in the thousands; cap what we render.
    @groupings = scoped.includes(:members)
                       .order(confidence: :asc, parent_name: :asc)
                       .limit(RENDER_LIMIT)
    @counts = policy_scope(CustomerGrouping).for_run(@run.id).group(:state).count
    @account_count = SfRecord.where(extraction_run_id: @run.id, object_api_name: "Account").count
    # Targets for the "merge into…" typeahead — the groupings under active review
    # (the natural canonical buckets to merge into), rendered once in a shared
    # <datalist>. parent_name is unique per run, so merge resolves by name. The
    # 19k+ auto-confirmed exact-dup buckets are intentionally excluded to keep the
    # page light; merging into one of those is a rare case we can add later.
    @merge_targets = policy_scope(CustomerGrouping).for_run(@run.id)
                     .where("state = 'open' OR user_modified = ?", true)
                     .order(:parent_name).pluck(:parent_name)
    # Existing customers already used as roll-up targets, for the "roll up
    # under…" typeahead (so you reuse "KINDER MORGAN" rather than retype it).
    @rollup_customers = policy_scope(CustomerGrouping).for_run(@run.id)
                        .rolled_up.distinct.order(:customer_name).pluck(:customer_name)
  end

  def detect
    authorize CustomerGrouping, :detect?
    return redirect_to customer_groupings_path, alert: "No active run." if @run.nil?

    stats = Sync::CustomerGroupingDetector.call(@run)
    redirect_to customer_groupings_path(run: @run.id),
                notice: "Detected groupings — #{stats[:groupings_created]} new, " \
                        "#{stats[:groupings_updated]} refreshed across #{stats[:accounts_scanned]} accounts."
  end

  def confirm
    authorize @grouping, :confirm?
    @grouping.update!(state: "confirmed", user_modified: true)
    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Confirmed grouping “#{@grouping.parent_name}”."
  end

  def reject
    authorize @grouping, :reject?
    @grouping.update!(state: "rejected", user_modified: true)
    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Rejected grouping “#{@grouping.parent_name}”."
  end

  def unreject
    authorize @grouping, :unreject?
    @grouping.update!(state: "open", user_modified: true)
    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Reopened grouping “#{@grouping.parent_name}”."
  end

  # Fold this grouping into a target grouping: the two are the same customer
  # (e.g. "CB RICHARD ELLIS" into "CBRE"). Records a durable alias so the merge
  # survives re-detection, moves members across (carrying their provenance), and
  # removes the now-empty absorbed grouping.
  def merge
    authorize @grouping, :merge?
    target = if params[:target_name].present?
               CustomerGrouping.for_run(@run.id).find_by(parent_name: params[:target_name].strip)
             else
               CustomerGrouping.find_by(id: params[:target_id])
             end
    if target.nil? || target.extraction_run_id != @run.id || target.id == @grouping.id
      return redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                         alert: "Pick a different existing grouping to merge into."
    end

    absorbed_name = @grouping.parent_name
    ActiveRecord::Base.transaction do
      CustomerGroupingAlias.find_or_create_by!(
        extraction_run_id: @run.id,
        alias_normalized: absorbed_name.to_s.squish.downcase
      ) { |a| a.absorbed_display_name = absorbed_name; a.canonical_parent_name = target.parent_name }

      @grouping.members.find_each do |m|
        if target.members.exists?(sailfin_account_id: m.sailfin_account_id)
          m.destroy            # target already has this account
        else
          m.update!(customer_grouping_id: target.id)   # source_parent_name preserved
        end
      end
      target.update!(user_modified: true)
      @grouping.destroy
    end

    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Merged “#{absorbed_name}” into “#{target.parent_name}”."
  end

  # Undo a merge: remove the alias and pull the absorbed grouping's members back
  # out (identified by their preserved source_parent_name).
  def unmerge
    authorize @grouping, :unmerge?
    alias_row = @grouping.merged_aliases.find_by(id: params[:alias_id])
    return redirect_to(customer_groupings_path(run: @run.id), alert: "No such merge.") if alias_row.nil?

    ActiveRecord::Base.transaction do
      restored = CustomerGrouping.find_or_create_by!(
        extraction_run_id: @run.id, parent_name: alias_row.absorbed_display_name
      ) { |g| g.detection_method = "name_prefix"; g.confidence = "medium"; g.state = "open" }

      @grouping.members
               .where(source_parent_name: alias_row.absorbed_display_name)
               .find_each { |m| m.update!(customer_grouping_id: restored.id) }

      alias_row.destroy
    end

    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Unmerged “#{alias_row.absorbed_display_name}” from “#{@grouping.parent_name}”."
  end

  # Nest many groupings under one customer in a single click. Each selected
  # grouping becomes a GROUP (auto-labeled by stripping the customer prefix)
  # under the customer ORG, and is confirmed so the importer applies it.
  def roll_up
    authorize CustomerGrouping, :roll_up?
    customer = params[:customer_name].to_s.strip
    ids = Array(params[:grouping_ids]).map(&:to_i)
    if customer.blank? || ids.empty?
      return redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                         alert: "Pick a customer name and at least one grouping to roll up."
    end

    groupings = policy_scope(CustomerGrouping).for_run(@run.id).where(id: ids)
    groupings.find_each do |g|
      g.update!(customer_name: customer,
                group_label: CustomerGrouping.derive_group_label(g.parent_name, customer),
                state: "confirmed", user_modified: true)
    end
    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Rolled #{groupings.size} grouping#{'s' unless groupings.size == 1} up under “#{customer}”."
  end

  # Pull a grouping back out of its customer (it becomes its own org again).
  def unroll
    authorize @grouping, :unroll?
    @grouping.update!(customer_name: nil, group_label: nil, user_modified: true)
    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Removed “#{@grouping.parent_name}” from its customer."
  end

  # Edit a rolled-up grouping's group label (the auto-derived default is a guess).
  def group_label
    authorize @grouping, :group_label?
    @grouping.update!(group_label: params[:group_label].to_s.strip.presence)
    redirect_to customer_groupings_path(state: params[:return_state], run: @run.id, q: params[:return_q]),
                notice: "Updated group label for “#{@grouping.parent_name}”."
  end

  private

  def load_run
    @run = current_run
  end

  def load_grouping
    @grouping = CustomerGrouping.find_by(id: params[:id])
    head :not_found if @grouping.nil? || @grouping.extraction_run_id != @run&.id
  end
end
