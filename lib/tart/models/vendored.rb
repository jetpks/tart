# frozen_string_literal: true

require "json"

module Tart
  module Models
    # The vendored pi catalogue tier (I71 R2): the provider model facts
    # copied verbatim into `vendor/pi-models/` (see that dir's
    # ATTRIBUTION.md), consulted at the FACT-RESOLUTION seams only. This is
    # a READ-ONLY metadata tier: the loaded models.json catalog is NEVER
    # mutated here (Models.load output / Config / model_entries /
    # Shapes::Model#to_h stay byte-stable) — the seams fill absent fields
    # from the matched vendored facts at read time.
    #
    # Match rule (frozen): a user provider block matches a vendored
    # provider when (a) the user `baseUrl` EQUALS the vendored provider's
    # `baseUrl` (string compare, case-insensitive, a single trailing `/`
    # stripped on both sides) — evaluated across the vendored providers; or
    # (b) the user provider declares NO `baseUrl` and its KEY equals the
    # vendored provider name (case-insensitive). Priority (a) over (b); NO
    # bare-id cross-provider fallback (a `zai`-keyed localhost base must
    # NOT match — the hermetic-test inertness law). Model match: the user
    # model `id` equals the vendored model `id` (case-insensitive) within
    # the matched provider.
    #
    # Loader discipline: raw JSON parse (NEVER through the models.json
    # CatalogContract — the vendored files carry pi's full schema, a
    # superset of the port's subset), lazily on first consultation
    # (require does nothing — no boot cost without a seam consult),
    # cached; a missing or unparseable vendor file degrades to that
    # provider being absent — never raises, never blocks boot, no MOTD
    # noise. Local file reads ONLY — no network anywhere in this module.
    module Vendored
      # The vendored data dir, resolved __dir__-relative: lib/tart/models/
      # → the tart root's vendor/pi-models/.
      VENDOR_DIR = File.expand_path("../../../vendor/pi-models", __dir__)

      # Sentinel recorded for a load-path provider block that declares NO
      # baseUrl (rule (b) — the KEY arm). Distinct from "never rode the
      # load path" (a hand-built Shapes::Provider — those entries match
      # NOTHING, which keeps the hand-staged test catalogs inert).
      NO_BASE_URL = Object.new.freeze

      class << self
        # (load path) Records each typed entry's provider-block baseUrl —
        # the seam lookups receive the bare entry, and the match rule needs
        # the BLOCK's baseUrl (Shapes::Model carries the provider KEY only).
        # Weak-keyed: the record dies with the entry object; hand-built
        # providers never register, and their entries match nothing.
        def register_entries(base_url, entries)
          entries.each { |entry| @base_urls[entry] = base_url.nil? ? NO_BASE_URL : base_url }
        end

        # The vendored model facts for a user entry (a typed Shapes::Model,
        # or the legacy raw-hash shape), or nil. NEVER raises (a lookup
        # failure is an absent tier, never an error).
        def facts_for_entry(entry)
          record = @base_urls[entry]
          return nil if record.nil? # never rode the load path — no match

          base_url = record.equal?(NO_BASE_URL) ? nil : record
          key = entry.respond_to?(:provider) ? entry.provider : entry[:provider]
          id = entry.respond_to?(:id) ? entry.id : entry[:id]
          facts_for(key, base_url, id)
        rescue StandardError
          nil
        end

        # The vendored model facts for a provider-scoped lookup (the
        # live-listing enrichment, R4): +provider_base_url+ nil = the block
        # declares no baseUrl (the KEY arm). NEVER raises.
        def facts_for(provider_key, provider_base_url, model_id)
          models = if provider_base_url
            # rule (a): the model's own baseUrl EQUALS the user block's
            # (case-insensitive, one trailing slash stripped) — a vendored
            # file may serve models under several baseUrls, so the model's
            # own field is the authoritative one.
            index[:by_base_url][normalize_base_url(provider_base_url)]
          else
            # rule (b): no baseUrl declared — the provider KEY equals the
            # vendored provider name (case-insensitive).
            index[:by_name][provider_key.to_s.downcase]
          end
          return nil unless models

          models[model_id.to_s.downcase]
        rescue StandardError
          nil
        end

        private

        def normalize_base_url(url)
          url.to_s.downcase.sub(/\/\z/, "")
        end

        # The index over the vendored data files, flattened across each
        # file's api buckets into two id-keyed tables — by the model's own
        # baseUrl (rule (a)) and by the model's provider name (rule (b));
        # values are the RAW pi facts hashes. Built lazily on FIRST
        # consultation, cached; a missing/corrupt file contributes nothing
        # (its provider is absent from the tier). Deterministic on exact
        # collisions: sorted file order, first model wins.
        def index
          @index ||= begin
            by_base_url = {}
            by_name = {}
            Dir[File.join(VENDOR_DIR, "*.json")].sort.each do |path|
              each_model(path) do |facts|
                id = facts["id"].downcase
                if facts["baseUrl"].is_a?(String)
                  bucket = (by_base_url[normalize_base_url(facts["baseUrl"])] ||= {})
                  bucket[id] ||= facts
                end
                if facts["provider"].is_a?(String)
                  bucket = (by_name[facts["provider"].downcase] ||= {})
                  bucket[id] ||= facts
                end
              end
            end
            {by_base_url:, by_name:}.freeze
          end
        end

        def each_model(path)
          parsed = JSON.parse(File.read(path))
          return unless parsed.is_a?(Hash)

          parsed.each_value do |bucket|
            next unless bucket.is_a?(Hash)

            bucket.each_value do |facts|
              next unless facts.is_a?(Hash) && facts["id"].is_a?(String)

              yield facts
            end
          end
        rescue StandardError
          nil
        end
      end

      @base_urls = ObjectSpace::WeakMap.new
    end
  end
end
