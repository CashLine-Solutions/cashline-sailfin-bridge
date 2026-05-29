require "test_helper"

class FieldAssessmentTest < ActiveSupport::TestCase
  setup do
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    @sfield = Sfield.create!(sobject: @sobject, api_name: "F__c")
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {})
  end

  def assessment(disposition)
    FieldAssessment.new(sfield: @sfield, cashline_snapshot: @snapshot, disposition: disposition)
  end

  test "the four dispositions are valid and labelled" do
    assert_equal %w[keep need_in_cashline sync_reference discard], FieldAssessment::DISPOSITIONS
    FieldAssessment::DISPOSITIONS.each { |d| assert assessment(d).valid?, "#{d} should be valid" }
    assert_equal "sailfin sync", assessment("sync_reference").disposition_label
  end

  test "an unknown disposition is rejected; nil is allowed" do
    assert_not assessment("maybe").valid?
    assert assessment(nil).valid?
  end
end
