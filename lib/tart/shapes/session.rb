# frozen_string_literal: true

require_relative "types"

module Tart
  module Shapes
    # The session-entry read-path family (I44 B3): typed VIEWS over the
    # recorded JSONL entries. The WRITE path (the entry factories,
    # Recorder#persist, the fork copy) stays Hash literals — the JSONL
    # bytes are the I07 pi-parity frozen surface; these classes see only
    # the READ side (loaded entries and their projections).
    #
    # Tolerance rule: the envelopes' `.of(raw)` constructor wraps
    # `new` in `rescue Dry::Struct::Error → nil`, reproducing today's
    # guard-chain nil-skips EXACTLY — a non-Hash, wrong-typed, role-less
    # or body-less entry reads nil, never a stray raise on a user surface.
    #
    # Byte rule: the projections' output (ContextMessage#to_h) pins the
    # recorded body's key order and the open recorded-message shape — the
    # resume seed crosses the gem's add_message seam and lands on the
    # wire; a re-ordered or trimmed hash would move bytes.

    # The envelope of one recorded message entry: the entry type gate plus
    # the open recorded-message body. +role+ rides UP from the body at
    # construction (the body's role must be a String — today's guard), so
    # the read sites branch on the attribute, not the raw hash. The body
    # itself stays the recorded open Hash (its key style is the recorded
    # one — the projection reads it exactly as loaded).
    class MessageEntry < Dry::Struct
      transform_keys(&:to_sym)

      attribute :type, Types::Strict::String.enum("message")
      attribute :role, Types::Strict::String
      attribute :message, Types::Strict::Hash

      # The tolerant constructor: nil for every malformed class today's
      # guards skip (non-Hash, non-"message" type, missing/non-Hash body,
      # missing/non-String role).
      def self.of(raw)
        return nil unless raw.is_a?(Hash)

        body = raw["message"] || raw[:message]
        new(raw.merge(role: body.is_a?(Hash) ? body["role"] || body[:role] : nil))
      rescue Dry::Struct::Error
        nil
      end
    end

    # The envelope of one compaction entry — the scan's view. The scanned
    # fields are nominal on purpose: strict typing would change the
    # malformed-entry outcomes (the summary's own String guard stays in
    # the projection; the id match compares raw recorded values).
    # firstKeptEntryId cannot ride the snake_case name through
    # transform_keys (the recorded key is camelCase), so .of promotes the
    # scanned fields under the Ruby-facing names.
    class CompactionEntry < Dry::Struct
      attribute :type, Types::Strict::String.enum("compaction")
      attribute? :id, Types::Nominal::Any
      attribute? :first_kept_entry_id, Types::Nominal::Any
      attribute? :summary, Types::Nominal::Any

      def self.of(raw)
        return nil unless raw.is_a?(Hash)

        new(
          type: entry_value(raw, "type"),
          id: entry_value(raw, "id"),
          first_kept_entry_id: entry_value(raw, "firstKeptEntryId"),
          summary: entry_value(raw, "summary")
        )
      rescue Dry::Struct::Error
        nil
      end

      # The first value present under the string or the symbol spelling
      # (loaded entries are string-keyed; the recorder's in-memory
      # projection is symbol-keyed).
      def self.entry_value(raw, string_key)
        symbol_key = string_key.to_sym
        raw.key?(string_key) ? raw[string_key] : raw[symbol_key]
      end
    end

    # The session header's discovery view: type + id gate the file
    # (String id), cwd rides nominal (the cwd match guards its own
    # type/emptiness), and the remaining keys are optional metadata.
    # parentSession keeps the recorded camelCase name — transform_keys
    # maps the recorded key verbatim.
    class SessionHeader < Dry::Struct
      transform_keys(&:to_sym)

      attribute :type, Types::Strict::String.enum("session")
      attribute :id, Types::Strict::String
      attribute? :cwd, Types::Nominal::Any
      attribute? :version, Types::Nominal::Any
      attribute? :timestamp, Types::Nominal::Any
      attribute? :parentSession, Types::Nominal::Any

      # The tolerant constructor: nil unless the raw first entry carries a
      # valid header shape. The raw recorded hash rides along (the
      # discovery-shape readers below read it verbatim).
      def self.of(raw)
        return nil unless raw.is_a?(Hash)

        new(raw).tap { |header| header.instance_variable_set(:@raw, raw) }
      rescue Dry::Struct::Error
        nil
      end

      # The recorded-key readers (the frozen discovery contract): the raw
      # recorded value under the string or symbol spelling — an absent
      # key reads nil, never a raise.
      def [](key)
        raw = @raw
        raw.key?(key) ? raw[key] : raw[key.to_s]
      end

      def key?(key)
        @raw.key?(key) || @raw.key?(key.to_s)
      end
    end

    # The chat-ready projection of one entry — the add_message attribute
    # hash (role symbolized, null/missing content as ""). The recorded
    # body rides WHOLE in its recorded key order: the seed crosses the
    # gem's add_message seam onto the wire, and a declared-attributes
    # to_h would both drop the open body's remaining keys (tool_calls,
    # tool_call_id) and re-order it. So the constructor pins the coerced
    # input and to_h emits it — the entry-coercion table (role
    # symbolization, null content → "") expressed as the type
    # declarations below, applied by construction.
    class ContextMessage < Dry::Struct
      transform_keys(&:to_sym)

      attribute :role, Types::Constructor(Types::Strict::Symbol) { |value| value.to_sym }
      # Nil maps to "" (the port's null-content rule); any other recorded
      # value rides verbatim — the projection never raised on it and this
      # type must not either (the tolerance rule above).
      attribute? :content, Types::Constructor(Types::Nominal::Any) { |value| value.nil? ? "" : value }

      # The splat forwards dry-struct's optional second positional
      # (safe) untouched; the existing-instance passthrough skips the pin.
      def self.new(attributes = {}, *, &block)
        object = super(attributes, *, &block)
        unless attributes.is_a?(Struct)
          fields = attributes.to_h.transform_keys(&:to_sym)
          fields[:role] = object.role
          if !fields.key?(:content) || fields[:content].nil?
            # A missing key gains :content LAST (today's append); a nil
            # maps to "" in place. The attribute is absent-when-missing,
            # so the empty string comes from here, not the type.
            fields[:content] = object.content || ""
          end
          object.instance_variable_set(:@fields, fields)
        end
        object
      end

      # The full coerced projection hash — recorded key order preserved.
      def to_h
        @fields
      end

      def inspect
        "#<#{self.class.name} #{to_h.inspect}>"
      end
    end
  end
end
