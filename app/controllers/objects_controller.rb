class ObjectsController < ApplicationController
  before_action :load_run
  after_action :verify_authorized, only: [:show]
  after_action :verify_policy_scoped, only: [:index]

  def index
    if @run.nil?
      @sobjects = policy_scope(Sobject.none)
      @sfield_counts = {}
      return
    end
    scope = policy_scope(Sobject.where(extraction_run: @run))
    scope = scope.where("api_name ILIKE ?", "%#{params[:q]}%") if params[:q].present?
    scope = filter_namespace(scope, params[:namespace]) if params[:namespace].present?
    @sobjects = scope.order(:api_name).to_a
    @sfield_counts = Sfield.where(sobject_id: @sobjects.map(&:id)).group(:sobject_id).count
  end

  def show
    load_show_data!
    @outgoing = Srelationship.where(source_sobject_id: @sobject.id).includes(:target_sobject, :source_field).to_a
    @incoming = Srelationship.where(target_sobject_id: @sobject.id).includes(:source_sobject, :source_field).to_a
  end

  # Inline-expand panel rendered inside a Turbo Frame on /objects.
  # Same data as #show minus relationship/formula sections so the inline
  # expand stays light. Reuses ObjectViewPolicy for authorization.
  def fields
    load_show_data!
    render layout: false
  end

  private

  def load_run
    @run = current_run
    head :not_found if @run.nil? && params[:api_name].present?
  end

  def load_show_data!
    @sobject = Sobject.where(extraction_run: @run).find_by!(api_name: params[:api_name])
    authorize @sobject, policy_class: ObjectViewPolicy
    @sfields = @sobject.sfields.includes(:spicklist_values).order(:api_name)
    @object_profile = ObjectProfile.find_by(extraction_run: @run, sobject: @sobject)
    @field_profiles = if @object_profile
      FieldProfile.where(object_profile_id: @object_profile.id).index_by(&:sfield_id)
    else
      {}
    end
  end

  def filter_namespace(scope, ns)
    return scope.where(namespace_prefix: nil).or(scope.where(namespace_prefix: "")) if ns == "standard"
    scope.where(namespace_prefix: ns)
  end
end
