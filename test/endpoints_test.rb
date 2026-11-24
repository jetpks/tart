# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # I120 provider-swap — Tart::Endpoints, the provider-keyed client/endpoint
  # registry: the mid-session chain (block apiKey via ConfigValue → the
  # settings FILE tier → the named refusal; baseUrl = the block's own only),
  # the BOOT-ONLY identity env tier (never consulted for a non-boot
  # provider — the trap this registry closes), the never-raise boot/carry
  # facts, and the per-provider in-process client cache.
  class EndpointsTest < Test
    def setup
      Endpoints.clear_cache
      @dir = Dir.mktmpdir("i120-endpoints-")
    end

    def teardown
      Endpoints.clear_cache
      FileUtils.rm_rf(@dir)
    end

    def catalog(alpha_key: "alpha-key", beta_key: "$BETA_KEY", beta_base: "https://beta.example/v1")
      Models::Config.new(
        providers: {
          "alpha" => Shapes::Provider.new(name: "Alpha", base_url: "https://alpha.example/v1",
            api_key: alpha_key, api: nil, models: [Shapes::Model.new(id: "a-1", name: "A", reasoning: false,
              context_window: 1000, max_tokens: nil, thinking_level_map: nil, compat: nil, provider: "alpha")]),
          "beta" => Shapes::Provider.new(name: "Beta", base_url: beta_base,
            api_key: beta_key, api: nil, models: [Shapes::Model.new(id: "b-1", name: "B", reasoning: false,
              context_window: 1000, max_tokens: nil, thinking_level_map: nil, compat: nil, provider: "beta")])
        },
        default: nil, error: nil
      )
    end

    def ref(provider)
      Shapes::ModelRef.new(provider: provider, id: "x-1")
    end

    # The mid-session chain: the block's own key and base, literal arm.
    def test_provider_swap_resolve_facts_reads_the_blocks_own_key_and_base
      facts = Endpoints.resolve_facts("alpha", models: catalog, env: {})
      assert_equal "alpha-key", facts.fetch(:api_key)
      assert_equal "https://alpha.example/v1", facts.fetch(:api_base)
    end

    # The block's apiKey resolves through the I119 grammar at THIS use seam.
    def test_provider_swap_resolve_facts_resolves_a_templated_block_key
      facts = Endpoints.resolve_facts("beta", models: catalog, env: {"BETA_KEY" => "beta-resolved"})
      assert_equal "beta-resolved", facts.fetch(:api_key)
      assert_equal "https://beta.example/v1", facts.fetch(:api_base)
    end

    # An unresolvable block template is the I119 NAMED failure — it
    # propagates unwrapped (pi's exact string) and never falls through to
    # the settings tier.
    def test_provider_swap_resolve_facts_propagates_the_unresolvable_template_by_name
      error = assert_raises(ConfigValue::UnresolvedError) do
        Endpoints.resolve_facts("beta", models: catalog, settings: {"apiKey" => "settings-key-must-not-fall-through"},
          env: {})
      end
      assert_equal 'Failed to resolve API key for provider "beta" from environment variable: BETA_KEY', error.message
    end

    # The `!command` cut composes: never executed, never sent.
    def test_provider_swap_resolve_facts_cuts_a_command_value
      canary = File.join(@dir, "canary")
      error = assert_raises(ConfigValue::CommandConfigValueError) do
        Endpoints.resolve_facts("alpha", models: catalog(alpha_key: "!touch #{canary}"), env: {})
      end
      assert_includes error.message, '"!command" values are not supported'
      refute File.exist?(canary), "nothing was executed"
    end

    # The settings FILE tier feeds a blockless key — read DIRECTLY from
    # the merged hash, never Settings.resolve_setting (which would re-read
    # the boot-only identity env tier).
    def test_provider_swap_resolve_facts_falls_to_the_settings_file_tier
      keyless = Models::Config.new(
        providers: {"gamma" => Shapes::Provider.new(name: "Gamma", base_url: "https://gamma.example/v1",
          api_key: nil, api: nil, models: [])},
        default: nil, error: nil)
      facts = Endpoints.resolve_facts("gamma", models: keyless, settings: {"apiKey" => "settings-file-key"}, env: {})
      assert_equal "settings-file-key", facts.fetch(:api_key)
    end

    # THE TRAP NEGATIVE: the identity env tier is BOOT-ONLY — a set
    # <IDENTITY>_API_KEY (the launcher's pin for the BOOT provider) never
    # feeds a DIFFERENT provider through the mid-session chain. This is
    # exactly the reported defect's shape, held closed.
    def test_provider_swap_resolve_facts_never_reads_the_identity_env_tier
      error = assert_raises(Endpoints::Error) do
        Endpoints.resolve_facts("gamma", models: catalog,
          settings: {"apiKey" => nil},
          env: {"TART_API_KEY" => "boot-provider-key", "TART_IDENTITY" => "tart"})
      end
      assert_equal 'No API key for provider "gamma"', error.message
    end

    # The named refusals: the key first, then the base (both missing ⇒ the
    # key message; key ok + baseless block ⇒ the base message).
    def test_provider_swap_resolve_facts_names_the_key_and_base_refusals
      baseless = Models::Config.new(
        providers: {"delta" => Shapes::Provider.new(name: "Delta", base_url: nil,
          api_key: "delta-key", api: nil, models: [])},
        default: nil, error: nil)
      key_error = assert_raises(Endpoints::Error) do
        Endpoints.resolve_facts("gamma", models: catalog, env: {})
      end
      assert_equal 'No API key for provider "gamma"', key_error.message
      base_error = assert_raises(Endpoints::Error) do
        Endpoints.resolve_facts("delta", models: baseless, env: {})
      end
      assert_equal 'No baseUrl for provider "delta"', base_error.message
    end

    # The per-provider client cache: forth-and-back reuses; distinct
    # providers get distinct clients; a `$VAR` key resolves ONCE per
    # process (the documented staleness — a later env change never
    # rebuilds).
    def test_provider_swap_provide_caches_one_client_per_provider
      first = Endpoints.provide("beta", models: catalog, env: {"BETA_KEY" => "beta-one"})
      again = Endpoints.provide("beta", models: catalog, env: {"BETA_KEY" => "beta-TWO"})
      assert_same first.fetch(:client), again.fetch(:client),
        "the $VAR key resolved ONCE per process (the documented staleness)"
      assert_equal "beta-one", again.fetch(:api_key), "the cached entry's OWN facts ride"

      alpha = Endpoints.provide("alpha", models: catalog, env: {})
      refute_same alpha.fetch(:client), first.fetch(:client), "distinct providers, distinct clients"

      Endpoints.clear_cache
      fresh = Endpoints.provide("beta", models: catalog, env: {"BETA_KEY" => "beta-two"})
      refute_same first.fetch(:client), fresh.fetch(:client), "clear_cache drops the process cache"
    end

    # The boot seat: seed reuses an equal entry (a /new re-boot never
    # churns clients) and is the authority for its own provider.
    def test_provider_swap_seed_reuses_equal_facts_and_replaces_differing_ones
      boot = Endpoints.seed("alpha", api_key: "boot-key", api_base: "https://alpha.example/v1")
      reseed = Endpoints.seed("alpha", api_key: "boot-key", api_base: "https://alpha.example/v1")
      assert_same boot.fetch(:client), reseed.fetch(:client), "the /new re-boot reuses the boot client"

      replaced = Endpoints.seed("alpha", api_key: "other-key", api_base: "https://alpha.example/v1")
      refute_same boot.fetch(:client), replaced.fetch(:client), "differing boot facts replace the entry"
    end

    # The boot chain lives here now: the env tier wins first, the block
    # resolves at the use seam, an unresolvable key is CARRIED (never a
    # raise — the never-raise boot law), and the facts name the provider
    # (the /new carryover's boot-provider marker).
    def test_provider_swap_boot_facts_chain_and_carried_error
      resolved = Struct.new(:api_key, :api_base).new(nil, "https://settings.example/v1")
      facts = Endpoints.boot_facts(catalog, ref("alpha"), identity: "tart", resolved:, env: {})
      assert_equal "alpha-key", facts.fetch(:api_key)
      assert_equal "https://alpha.example/v1", facts.fetch(:api_base)
      assert_equal "alpha", facts.fetch(:provider)
      assert_nil facts.fetch(:api_key_error)

      tiered = Endpoints.boot_facts(catalog, ref("alpha"), identity: "tart", resolved:,
        env: {"TART_API_KEY" => "launcher-pin", "TART_API_BASE" => "https://pin.example/v1"})
      assert_equal "launcher-pin", tiered.fetch(:api_key), "the env tier wins at boot"
      assert_equal "https://pin.example/v1", tiered.fetch(:api_base)

      carried = Endpoints.boot_facts(catalog, ref("beta"), identity: "tart", resolved:, env: {})
      assert_nil carried.fetch(:api_key), "the unresolvable template boots keyless"
      assert_instance_of ConfigValue::UnresolvedError, carried.fetch(:api_key_error)
    end

    # The never-raise carry arm (the /new carryover to a provider whose key
    # or base does not resolve): keyless + the named error carried, the
    # base falling to the caller's fallback (the gem's Client cannot
    # construct on nil — inert, request_error raises before any wire I/O).
    def test_provider_swap_carry_facts_never_raises
      carried = Endpoints.carry_facts("beta", models: catalog, settings: nil,
        fallback_base: "https://settings.example/v1", env: {})
      assert_nil carried.fetch(:api_key)
      assert_equal "https://beta.example/v1", carried.fetch(:api_base), "the block's own base"
      assert_instance_of ConfigValue::UnresolvedError, carried.fetch(:api_key_error)

      baseless = Models::Config.new(
        providers: {"delta" => Shapes::Provider.new(name: "Delta", base_url: nil,
          api_key: "delta-key", api: nil, models: [])},
        default: nil, error: nil)
      refused = Endpoints.carry_facts("delta", models: baseless,
        fallback_base: "https://settings.example/v1", env: {})
      assert_nil refused.fetch(:api_key), "a refused arm is UNIFORMLY keyless (the error gates the wire)"
      assert_equal 'No baseUrl for provider "delta"', refused.fetch(:api_key_error).message
      assert_equal "https://settings.example/v1", refused.fetch(:api_base), "the base fell to the fallback"
    end
  end
end
