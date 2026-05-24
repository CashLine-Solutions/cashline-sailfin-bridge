require "test_helper"

module Ontology
  class ModularityClustererTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email_address: "c@example.com", password: "secret-pass-1", role: :analyst)
      @run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [], include_sensitive: false)
    end

    test "two disconnected triangles cluster into the two components" do
      a, b, c = %w[A B C].map { |n| Sobject.create!(extraction_run: @run, api_name: n, raw_describe: {}) }
      d, e, f = %w[D E F].map { |n| Sobject.create!(extraction_run: @run, api_name: n, raw_describe: {}) }
      [ [ a, b ], [ b, c ], [ a, c ], [ d, e ], [ e, f ], [ d, f ] ].each do |src, tgt|
        Srelationship.create!(extraction_run: @run, source_sobject: src, target_sobject: tgt)
      end

      graph = RelationshipGraph.build(@run)
      groups = ModularityClusterer.cluster(graph)

      ids = groups.map(&:sort)
      assert_includes ids, [ a.id, b.id, c.id ].sort
      assert_includes ids, [ d.id, e.id, f.id ].sort
      assert_equal 2, ids.size
    end

    test "isolated nodes form singleton clusters" do
      a = Sobject.create!(extraction_run: @run, api_name: "Lone", raw_describe: {})
      groups = ModularityClusterer.cluster(RelationshipGraph.build(@run))
      assert_equal [ [ a.id ] ], groups
    end

    test "single edge yields one cluster" do
      a = Sobject.create!(extraction_run: @run, api_name: "X", raw_describe: {})
      b = Sobject.create!(extraction_run: @run, api_name: "Y", raw_describe: {})
      Srelationship.create!(extraction_run: @run, source_sobject: a, target_sobject: b)
      groups = ModularityClusterer.cluster(RelationshipGraph.build(@run))
      assert_equal [ [ a.id, b.id ].sort ], groups.map(&:sort)
    end
  end
end
