# frozen_string_literal: true

require_relative "config_value"
require_relative "identity"
require_relative "models"

module Tart
  # I120 provider-swap — the provider-keyed client/endpoint registry: ONE
  # resolution seam for the boot facts, the mid-session `/model` switch, the
  # `/new` carryover, and the subagent spawn seat, so "the endpoint" stops
  # being a session-lifetime fact (the boot client was frozen across every
  # consumer — the reported 400 family, I119 OQ-5's named follow-up
  # `endpoint-follows-switch`, redesigned owner 2026-11-24).
  #
  # The gem's Fast::Completions::Client is endpoint-immutable (one
  # base_url/api_key, client.rb:70-103) — worked WITH, never around: the
  # registry builds ONE client per provider and hands it to the consumers.
  #
  # The identity env tier (<IDENTITY>_API_KEY/_API_BASE) is BOOT-ONLY — it
  # is the LAUNCHER's pin for the provider the launcher booted
  # ({boot_facts}, today's bin/tart endpoint_facts chain verbatim). Letting
  # it follow a mid-session switch would send the boot provider's key to
  # another provider (the trap this registry closes), so the mid-session
  # chain ({resolve_facts}) never reads it: block apiKey → the settings FILE
  # tier → refusal; baseUrl = the block's own only.
  #
  # Per-provider in-process client cache ({provide}/{seed}): switching
  # forth and back reuses the first client; a `$VAR` apiKey resolves ONCE
  # per process (the staleness is the documented pi composed-model caching
  # trade — pi re-resolves per request; tart's gem client is immutable, so
  # the process-lifetime cache is the coarsest faithful shape).
  module Endpoints
    # The named refusal family (pi's setModel throw shape,
    # agent-session.ts:2659-2662 `No API key for ${provider}/${model}` —
    # the registry is provider-keyed, so the message names the provider;
    # itemized near-parity). A ConfigValue::Error (an unresolvable block
    # template) propagates UNWRAPPED — it is already the named failure with
    # pi's exact strings.
    class Error < StandardError; end

    CLIENT_TIMEOUT = 120

    module_function

    # The BOOT chain — bin/tart's endpoint_facts, moved home: the
    # identity-namespaced env tier wins FIRST (the launcher pin), else the
    # provider block's apiKey resolves HERE at the use seam (I119: a
    # template naming an unset/empty variable or a `!command` value yields
    # api_key nil + api_key_error — never a raise, never a fall-through to
    # another key), else the resolved-settings view's key; the base:
    # env tier || the block || the resolved view. NEVER raises (the
    # never-raise boot law; build_chat carries api_key_error onto the Chat
    # as request_error and the first request fails by name).
    #
    # @return [Hash] {provider:, api_key:, api_base:, api_key_error:}
    def boot_facts(models, ref, identity:, resolved:, env: ENV)
      provider = models.provider(ref.provider)
      key = env[Identity.env_key(identity, "API_KEY")]
      error = nil
      if key.nil? && provider && !provider.api_key.nil?
        begin
          key = ConfigValue.resolve!(provider.api_key, "API key for provider \"#{ref.provider}\"", env:)
        rescue ConfigValue::Error => e
          error = e
        end
      end
      key = resolved.api_key if key.nil? && error.nil?
      {
        provider: ref.provider,
        api_key: key,
        api_base: env[Identity.env_key(identity, "API_BASE")] || provider&.base_url || resolved.api_base,
        api_key_error: error
      }
    end

    # The MID-SESSION chain (the `/model` switch, the `/new` carryover to a
    # non-boot provider, the subagent spawn seat): the block's own key and
    # base only, plus the settings FILE tier for the key. NEVER the
    # identity env tier (boot-only, the launcher pin) and never the boot
    # endpoint — a different provider's key/base can never leak in.
    # RAISES on refusal (the named failure the consumers surface: the
    # switch's error row, the spawn's {error:} tool result; the boot-style
    # consumers wrap it through {carry_facts} instead of raising).
    #
    # @param settings [Hash, nil] the merged settings hash (Settings.load
    #   Result#settings) — the FILE tier source; `settings["apiKey"]` is
    #   read directly, never Settings.resolve_setting (that would re-read
    #   the identity env tier).
    # @return [Hash] {api_key:, api_base:}
    def resolve_facts(provider_key, models:, settings: nil, env: ENV)
      provider = models.provider(provider_key)
      key = nil
      if provider && !provider.api_key.nil?
        key = ConfigValue.resolve!(provider.api_key, "API key for provider \"#{provider_key}\"", env:)
      elsif settings && !settings["apiKey"].nil?
        key = settings["apiKey"]
      end
      raise Error, "No API key for provider \"#{provider_key}\"" if key.nil? || key.empty?

      base = provider&.base_url
      raise Error, "No baseUrl for provider \"#{provider_key}\"" if base.nil? || base.empty?

      {api_key: key, api_base: base}
    end

    # The never-raise wrapper over {resolve_facts} — the I119 discipline at
    # the boot-like seams (the `/new` carryover to a provider whose key or
    # base does not resolve: the client builds KEYLESS and the Chat carries
    # the named error for its first request; nothing reaches the wire, the
    # session boots). The refused arm's base falls to +fallback_base+ (the
    # caller's resolved-settings view — inert: request_error raises before
    # any wire I/O, but the gem's Client cannot CONSTRUCT on a nil base).
    #
    # @return [Hash] {provider:, api_key:, api_base:, api_key_error:}
    def carry_facts(provider_key, models:, settings: nil, fallback_base: nil, env: ENV)
      begin
        facts = resolve_facts(provider_key, models:, settings:, env:)
        error = nil
      rescue ConfigValue::Error, Error => e
        facts = {api_key: nil, api_base: models.provider(provider_key)&.base_url || fallback_base}
        error = e
      end
      {provider: provider_key, api_key_error: error}.merge(facts)
    end

    # The per-provider client cache's get-or-build: the FIRST resolution for
    # a provider is the process-lifetime authority (a cache hit returns the
    # cached client + ITS OWN facts — the `$VAR` staleness, documented
    # above); a miss resolves through {resolve_facts} (may raise — the
    # switch's named refusal) and caches the built client. The boot
    # provider's client is seeded by {seed} at boot, so a switch back to it
    # is always a cache hit — the launcher pin's key rides home unchanged.
    #
    # @return [Hash] {client:, api_key:, api_base:}
    def provide(provider_key, models:, settings: nil, env: ENV)
      cached = cache[provider_key]
      return cached if cached

      facts = resolve_facts(provider_key, models:, settings:, env:)
      seed(provider_key, api_key: facts.fetch(:api_key), api_base: facts.fetch(:api_base))
    end

    # The boot seat's cache writer: get-or-build for EXPLICIT facts (the
    # boot chain's own resolution — env tier included). An existing entry
    # with the SAME key+base is reused (the `/new` re-boot of the boot
    # provider never churns clients); differing facts REPLACE the entry
    # (the boot chain is the authority for its own provider).
    #
    # @return [Hash] {client:, api_key:, api_base:}
    def seed(provider_key, api_key:, api_base:)
      cached = cache[provider_key]
      return cached if cached && cached[:api_key] == api_key && cached[:api_base] == api_base

      entry = {
        client: Fast::Completions::Client.new(base_url: api_base, api_key: api_key, timeout: CLIENT_TIMEOUT),
        api_key: api_key, api_base: api_base
      }
      cache[provider_key] = entry
      entry
    end

    # The test seam: the per-process cache is dropped. NO production
    # caller (a process boots once; the cache's lifetime IS the point).
    def clear_cache
      cache.clear
      nil
    end

    # The plain per-process cache (a Hash, lock-free: the write seats —
    # boot and the reactor-surface switch — are same-fiber or idempotent;
    # the I107 census law keeps Mutexes out of lib/).
    def cache
      @cache ||= {}
    end

    private_class_method :cache
  end
end
