# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

module Tart
  # The seat-hermeticity pins (I104 lever e): the require-time ambient
  # TART_* scrub's laws — namespace removal, the harness-key exemption,
  # the snapshot/restore pair, and the mechanism (a laden seat's boot
  # resolution reads the STAGED catalog, never the ambient namespace).
  # Each pin re-invokes the scrub itself, so every pin is
  # order-independent under minitest's seeded shuffle.
  class EnvHermeticityTest < Test
    # The representative driver-seat keys (the finding's namespace).
    LADEN = {
      "TART_PROVIDER" => "zai",
      "TART_MODEL" => "glm-5.3",
      "TART_SESSION_FILE" => "/tmp/t104-hermetic-sess.jsonl",
      "TART_API_BASE" => "https://laden.example/v1"
    }.freeze

    # A staged catalog whose default is unmistakably NOT any ambient env
    # model: after the scrub the staged default wins; at an unscrubbed
    # laden seat the env tier does (the provider-alone shape is the
    # recorded base defect — a Dry::Struct::Error at resolve_boot_model
    # when the staged settings carry no default model id).
    STAGED_CATALOG = <<~JSON
      {
        "default": "stage/stage-default",
        "providers": {
          "stage": {
            "name": "Staged",
            "baseUrl": "https://staged.example/v1",
            "apiKey": "k-staged",
            "api": "openai-completions",
            "models": [{"id": "stage-default", "name": "Staged Default"}]
          }
        }
      }
    JSON

    def setup
      @saved_env = ENV.keys.grep(/\ATART_/).to_h { |key| [key, ENV[key]] }
      LADEN.each { |key, value| ENV[key] = value }
    end

    def teardown
      ENV.keys.grep(/\ATART_/).each { |key| ENV.delete(key) }
      @saved_env.each { |key, value| ENV[key] = value }
    end

    def test_scrub_removes_the_ambient_tart_namespace
      Test.scrub_seat_env!
      LADEN.each_key do |key|
        refute ENV.key?(key), "expected the ambient seat key #{key} scrubbed"
      end
    end

    def test_scrub_preserves_the_harness_keys
      ENV["TART_TEST_JOBS"] = "4"
      ENV["TART_E2E_SPACE"] = "/tmp/t104-hermetic-space"
      Test.scrub_seat_env!
      assert_equal "4", ENV["TART_TEST_JOBS"]
      assert_equal "/tmp/t104-hermetic-space", ENV["TART_E2E_SPACE"]
    end

    def test_scrub_snapshots_and_restores
      Test.scrub_seat_env!
      snapshot = Test::SEAT_TART_ENV
      assert_equal LADEN, snapshot
      assert_predicate snapshot, :frozen?
      LADEN.each_key { |key| refute ENV.key?(key), "expected #{key} scrubbed" }
      Test.restore_seat_env!
      LADEN.each { |key, value| assert_equal value, ENV[key] }
    end

    def test_boot_resolution_uses_the_staged_catalog_under_a_laden_seat
      Test.scrub_seat_env!
      Dir.mktmpdir("t104-hermetic-") do |root|
        File.write(File.join(root, "models.json"), STAGED_CATALOG)
        boot = Models.resolve_boot_model(Models.load(root: root), {},
          identity: Identity::DEFAULT)
        assert_equal({provider: "stage", id: "stage-default"}, boot.to_h)
      end
    end
  end
end
