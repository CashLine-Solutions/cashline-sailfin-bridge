require "test_helper"

class CustomerGroupingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "grouping-admin-#{SecureRandom.hex(4)}@example.com",
                         password: "password123", role: :admin, sensitive_data_access: true)
    sign_in_as(@user)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false,
                                 status: "complete", completed_at: Time.current)
    SfRecord.create!(extraction_run: @run, object_api_name: "Account", sf_id: "001x",
                     exported_at: Time.current, payload: { "Id" => "001x", "Name" => "Kinder Morgan" })

    @kinder = grouping("KINDER MORGAN")
    @atmos  = grouping("ATMOS ENERGY CORPORATION")
  end

  # Assert on the grouping *card* (its <h2 title="…">), not raw body text — every
  # grouping name also appears in the merge-typeahead <datalist>, which is
  # intentionally unfiltered by search.
  test "search filters the queue by parent name" do
    get customer_groupings_path(run: @run.id, state: "open", q: "kinder")
    assert_response :success
    assert_select %(h2[title="KINDER MORGAN"])
    assert_select %(h2[title="ATMOS ENERGY CORPORATION"]), count: 0
  end

  test "no query renders the full (uncapped-by-search) list" do
    get customer_groupings_path(run: @run.id, state: "open")
    assert_response :success
    assert_select %(h2[title="KINDER MORGAN"])
    assert_select %(h2[title="ATMOS ENERGY CORPORATION"])
  end

  test "a search miss shows a clear empty message, not 'nothing in tab'" do
    get customer_groupings_path(run: @run.id, state: "open", q: "zzzz-no-match")
    assert_response :success
    assert_match "match", @response.body
    assert_select %(h2[title="KINDER MORGAN"]), count: 0
  end

  test "confirm preserves the search query on redirect" do
    post confirm_customer_grouping_path(@kinder, run: @run.id, return_state: "open", return_q: "kinder")
    assert_redirected_to customer_groupings_path(state: "open", run: @run.id, q: "kinder")
    assert_equal "confirmed", @kinder.reload.state
  end

  test "roll_up nests selected groupings under a customer with derived, confirmed labels" do
    a = grouping("KINDER MORGAN / NGPL")
    b = grouping("KINDER MORGAN / SNG")
    post roll_up_customer_groupings_path(run: @run.id),
         params: { grouping_ids: [ a.id, b.id ], customer_name: "KINDER MORGAN", return_state: "open" }
    assert_redirected_to customer_groupings_path(state: "open", run: @run.id)
    assert_equal [ "KINDER MORGAN", "NGPL", "confirmed" ], [ a.reload.customer_name, a.group_label, a.state ]
    assert_equal "SNG", b.reload.group_label
  end

  test "a rolled-up grouping renders its customer chip and editable label" do
    a = grouping("KINDER MORGAN / NGPL")
    a.update!(customer_name: "KINDER MORGAN", group_label: "NGPL")
    get customer_groupings_path(run: @run.id, state: "open")
    assert_response :success
    assert_select "input[name=group_label][value=NGPL]"
  end

  test "unroll clears the customer and label" do
    a = grouping("KINDER MORGAN / NGPL")
    a.update!(customer_name: "KINDER MORGAN", group_label: "NGPL")
    post unroll_customer_grouping_path(a, run: @run.id, return_state: "open")
    assert_nil a.reload.customer_name
    assert_nil a.group_label
  end

  test "group_label edits a rolled-up grouping's label" do
    a = grouping("KINDER MORGAN / NGPL")
    a.update!(customer_name: "KINDER MORGAN", group_label: "NGPL")
    patch group_label_customer_grouping_path(a, run: @run.id, return_state: "open"),
          params: { group_label: "Natural Gas PL" }
    assert_equal "Natural Gas PL", a.reload.group_label
  end

  private

  def grouping(name)
    CustomerGrouping.create!(extraction_run: @run, parent_name: name,
                             detection_method: "test", confidence: "high", state: "open")
  end
end
