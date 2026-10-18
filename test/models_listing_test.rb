# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require_relative "../lib/tart/models/listing"

module Tart
  # The live /v1/models listing (I71 R3/R4/AC3/AC4): the ONE bounded,
  # authenticated GET against the configured provider's own endpoint —
  # every failure class ⇒ nil, one attempt, nothing raised; the GET path
  # + Bearer pinned from the captured request log; and the boot-inertness
  # law (a constructed surface makes ZERO requests — the fetch rides the
  # menu-open path only).
  class ModelsListingTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-listing-")
      FileUtils.mkdir_p(@dir)
      @server = MockLLMServer.new.start
      @server.script([{type: :models, ids: ["m-1", "m-2"]}])
    end

    def teardown
      @server.stop
      FileUtils.rm_rf(@dir)
    end

    # --- the fetch contract ---

    def test_fetch_returns_the_listed_ids
      assert_equal ["m-1", "m-2"], Models::Listing.fetch(base_url: @server.url, api_key: "k")
    end

    def test_fetch_speaks_the_get_models_path_with_the_bearer_header
      Models::Listing.fetch(base_url: @server.url, api_key: "sekrit")

      log = @server.captured_request_logs.first
      assert_equal "GET", log.fetch(:method), "the listing is a GET"
      assert_equal "/models", log.fetch(:path), "the OpenAI-compatible /models path"
      assert_equal "Bearer sekrit", log.fetch(:headers).fetch("authorization")
    end

    def test_fetch_is_a_single_attempt_no_retries
      Models::Listing.fetch(base_url: @server.url, api_key: "k")

      assert_equal 1, @server.request_count, "one fetch, NO retries/backoff"
    end

    # --- the failure matrix (AC4): every class ⇒ nil, bounded ---

    def test_dead_endpoint_returns_nil_within_the_bound
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Models::Listing.fetch(base_url: "http://127.0.0.1:1/v1", api_key: "k", timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      assert_nil result, "connect refused ⇒ nil, nothing raised"
      assert_operator elapsed, :<, Models::Listing::TIMEOUT + Models::Listing::JOIN_MARGIN,
        "the fetch is bounded by the frozen timeout"
    end

    def test_malformed_body_returns_nil
      @server.script([{type: :models, raw: "{not json"}])

      assert_nil Models::Listing.fetch(base_url: @server.url, api_key: "k")
    end

    def test_non_200_returns_nil_and_stays_a_single_attempt
      @server.script([{type: :models, ids: [], status: 500}])

      assert_nil Models::Listing.fetch(base_url: @server.url, api_key: "k")
      assert_equal 1, @server.request_count
    end

    def test_data_less_body_returns_nil
      @server.script([{type: :models, raw: JSON.generate({object: "list"})}])

      assert_nil Models::Listing.fetch(base_url: @server.url, api_key: "k"), "no data array ⇒ malformed ⇒ nil"
    end

    def test_empty_data_array_is_a_success
      @server.script([{type: :models, ids: []}])

      assert_empty Models::Listing.fetch(base_url: @server.url, api_key: "k"),
        "an empty listing is a landed (empty) success, not a failure"
    end

    # --- the boot-inertness law (AC4): NO network at boot ---

    def test_surface_construction_and_footer_facts_make_zero_requests
      in_surface do |chat, session, server|
        draw(chat, session)
        assert_equal 0, server.request_count,
          "constructing the Chat and reading the footer facts makes ZERO requests"
      end
    end

    def test_menu_open_makes_exactly_one_request_and_merges
      in_surface do |chat, session, server|
        draw(chat, session)
        chat.open_model_menu
        wait_until { server.request_count == 1 }
        assert_equal 1, server.request_count, "ONE fetch per menu open"

        # The merge rides the callback thread; the listed ids land in the
        # menu when the fetch resolves.
        wait_until { menu_ids(chat).include?("m-1") }
        assert_includes menu_ids(chat), "m-2"
      end
    end

    private

    # The headless surface over a staged load-path catalog whose provider
    # block carries BOTH baseUrl and apiKey pointing at the mock (rule
    # (a) — the block's baseUrl is what the fetch speaks, so the mock
    # answers; no env fallback needed).
    def in_surface
      File.write(File.join(@dir, "models.json"), JSON.generate({"default" => "zai/glm-5.3",
        "providers" => {"zai" => {"name" => "Z.AI", "baseUrl" => @server.url, "apiKey" => "k",
          "models" => [{"id" => "glm-5.3", "reasoning" => true}]}}}))
      models = Models.load(root: @dir)
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: ListingIdleKernel.new, motd: false,
          models:, endpoint: {api_key: "k", api_base: @server.url},
          footer_data: {cwd: @dir, model: "glm-5.3", default_provider: "zai"})
        yield chat, session, @server
      end
    end

    def menu_ids(chat)
      chat.instance_variable_get(:@menu)&.instance_variable_get(:@filtered)&.map { |item| item[:id] } || []
    end

    def draw(chat, session)
      session.draw(chat.renderer.call)
    end

    # The headless test kernel double (the chat_test IdleKernel shape —
    # local to this file: the listing tests need no kernel behavior).
    class ListingIdleKernel
      def request_draw = nil

      def animate(duration:) = nil

      def tick(interval) = nil
    end
  end
end
