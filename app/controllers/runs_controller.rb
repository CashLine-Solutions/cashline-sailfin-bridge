class RunsController < ApplicationController
  before_action :set_run, only: [ :show, :select ]
  after_action :verify_authorized, except: [ :select ]

  PRESET_SEED_OBJECTS = {
    "ar_default" => %w[Account Contact Opportunity],
    "ar_full" => %w[Account Contact Opportunity Task Event User RecordType],
    "sailfin_scope" => %w[
      Account Contact Opportunity
      Brand__c Business_Entity__c Open_Invoices__c Reporting_Client__c
      DSO_Report__c Weekly_AR_Snapshot__c Account_Brand_Association__c
    ]
  }.freeze

  # Presets that also override walk_options. Without a preset entry here, the
  # job defaults apply (namespace_allowlist = [nil, ""], max_hops = 3).
  PRESET_WALK_OPTIONS = {
    "sailfin_scope" => {
      "namespace_allowlist" => [ nil, "", "sfsrm", "sfcapp" ],
      "standard_allowlist"  => %w[Account Contact User RecordType Opportunity Task Event Pricebook2 Profile],
      "max_hops"            => 4
    }
  }.freeze

  def index
    authorize ExtractionRun
    scope = policy_scope(ExtractionRun)
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(include_sensitive: params[:include_sensitive] == "1") if params[:include_sensitive].present?
    @runs = scope.order(created_at: :desc).limit(100).to_a
    # Pre-load sobject counts so the index table renders in 2 queries
    # instead of (1 + N) — every row called run.sobjects.count before.
    @sobject_counts = Sobject.where(extraction_run_id: @runs.map(&:id)).group(:extraction_run_id).count
  end

  def show
    authorize @run
  end

  def new
    @run = ExtractionRun.new(api_version: Salesforce::API_VERSION)
    authorize @run
  end

  def create
    @run = ExtractionRun.new(create_params)
    @run.user = Current.user
    @run.status = "queued"
    @run.api_version ||= Salesforce::API_VERSION

    if @run.include_sensitive
      authorize @run, :trigger_with_pii?
    else
      authorize @run, :create?
    end

    if @run.save
      AuditEvent.record!(
        user: Current.user,
        action: "run.trigger",
        subject: @run,
        params: { include_sensitive: @run.include_sensitive, seed_objects: @run.seed_objects },
        request: request
      )
      ExtractDescribeJob.perform_later(@run.id)
      session[:active_run_id] = @run.id
      redirect_to run_path(@run), notice: "Run queued."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def select
    return head :not_found if @run.nil?
    authorize @run, :select_active?
    session[:active_run_id] = @run.id
    redirect_back_or_to run_path(@run), notice: "Active run set."
  end

  private

  def set_run
    @run = ExtractionRun.find_by(id: params[:id])
  end

  def create_params
    permitted = params.require(:extraction_run).permit(:include_sensitive, :api_version, :preset, seed_objects: [], walk_options: {})
    if (preset = permitted.delete(:preset)).present? && PRESET_SEED_OBJECTS.key?(preset)
      permitted[:seed_objects] = PRESET_SEED_OBJECTS[preset]
      # If the preset declares walk_options, use them. Otherwise fall back to
      # the job's DEFAULT_WALK_OPTIONS, which keeps the walk inside the
      # standard namespace.
      if (preset_walk = PRESET_WALK_OPTIONS[preset])
        permitted[:walk_options] = preset_walk
      end
    end
    permitted[:seed_objects] = Array(permitted[:seed_objects]).reject(&:blank?)
    permitted
  end
end
