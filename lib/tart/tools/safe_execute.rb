# frozen_string_literal: true

require_relative "../schemas/tools"

module Tart
  module Tools
    # Shared behavior of the built-in tools: every execution failure comes
    # back to the model as an {error: message} result (pi's agent loop turns
    # tool errors into error tool results), never as a loop crash. Cancellation
    # always propagates.
    module SafeExecute
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # The name the model calls this tool by; explicit so class renames
        # never change the wire name.
        def pi_name(name = nil)
          @pi_name = name unless name.nil?
          @pi_name
        end

        # The declared property names (Strings). `properties` is read under
        # BOTH top-level key spellings — both spellings exist across the
        # fourteen schema literals (I97 Grounds, measured).
        def declared_properties
          schema = parameters
          (schema[:properties] || schema["properties"] || {}).keys.map(&:to_s)
        end

        # I97 Law 1 — the schema is the SINGLE hand-maintained declaration
        # of a tool's argument surface; the binding map is DERIVED from the
        # declared parameters schema. Wire property name (String) → its
        # snake_case execute kwarg (Symbol); camelCase folds per
        # `gsub(/([A-Z])/) { "_" + $1.downcase }` (ignoreCase → :ignore_case;
        # already-snake names are identity). Memoized per class. No tool
        # file hand-maintains any mapping, anywhere.
        def wire_to_kwargs
          @wire_to_kwargs ||= declared_properties.each_with_object({}) do |name, map|
            map[name] = name.gsub(/([A-Z])/) { "_" + $1.downcase }.to_sym
          end
        end

        # The memoized inverse (snake Symbol → wire Symbol) — the seam and
        # the in-body consult speak WIRE with it (Laws 3 and 5).
        def kwargs_to_wire
          @kwargs_to_wire ||= wire_to_kwargs.each_with_object({}) do |(wire, kwarg), map|
            map[kwarg] = wire.to_sym
          end
        end

        # I97 Law 2 — the boot proof (drift is UNEXPRESSIBLE): snake(declared
        # properties) must be collision-free and SET-EQUAL to #execute's
        # keyword parameters minus :tool_call. A drifted tool — a declared
        # property whose snake name is no execute keyword (the #21 shape),
        # an execute keyword no property advertises (the reverse, OQ 3), two
        # properties colliding on one snake kwarg — RAISES a loud
        # ArgumentError naming the tool and both direction sets. Boundary
        # (OQ 2): snake({}) == [] enforces that a tool with no declared
        # schema takes zero keywords. Memoized per class; Registry.build
        # runs it over the assembled loadout BEFORE the ToolGate wrap, so a
        # drifted tool is unloadable — no loadout, no wire declaration, no
        # call.
        def verify_schema_binding!
          return true if @schema_binding_verified

          props = declared_properties
          keywords = instance_method(:execute).parameters
                                              .select { |(kind, _name)| %i[key keyreq].include?(kind) }
                                              .map(&:last) - [:tool_call]
          snakes = props.map { |name| wire_to_kwargs.fetch(name) }
          collided = snakes.tally.select { |_snake, count| count > 1 }.keys
          if collided.any?
            raise ArgumentError,
                  "schema↔execute drift on tool #{pi_name.inspect}: schema properties #{props.inspect} " \
                  "collide on snake_case keyword(s) #{collided.inspect}"
          end

          unmapped = props.reject { |name| keywords.include?(wire_to_kwargs.fetch(name)) }
          unadvertised = keywords.reject { |kwarg| snakes.include?(kwarg) }
          if unmapped.any? || unadvertised.any?
            raise ArgumentError,
                  "schema↔execute drift on tool #{pi_name.inspect}: " \
                  "properties with no execute keyword: #{unmapped.inspect}; " \
                  "execute keywords no schema property advertises: #{unadvertised.inspect}"
          end

          @schema_binding_verified = true
        end

        # I97 Law 4 — installs this tool's schema-derived input contract
        # ({Schemas::Tools.install_derived}), keyed by the wire name. The
        # nine contracted tools call this ONCE, immediately after their
        # `parameters` declaration; the contract-less names install nothing
        # (the KeyError belt holds — I96 D3).
        def schema_contract
          raise ArgumentError, "schema_contract: #{self} declares no pi_name or parameters" unless pi_name && parameters

          Schemas::Tools.install_derived(pi_name, self)
        end
      end

      def name
        self.class.pi_name
      end

      # The compaction estimate's schema reader — the wire's parameters
      # (the gem's verbatim declaration), one reader for the estimate and
      # the tests.
      def parameters_schema
        self.class.parameters
      end

      # The execution seam (the replaced client's Tool#call contract — the
      # batch executor and the ToolGate land here): the provider's parsed
      # arguments speak string keys, the schema speaks symbols; the
      # +tool_call+ duck rides only when #execute declares the keyword
      # (the replaced client's execute_accepts_tool_call? idiom).
      def call(tool_call: nil, **arguments)
        normalized = arguments.transform_keys(&:to_sym)
        # I97 Law 3 — the seam owns the translation (ONE place, schema-derived
        # from Law 1's map): ONLY schema-declared keys rename camel→snake,
        # every other key passes through UNTOUCHED — an off-schema key still
        # binds-or-raises exactly as today. The rescue below consults and
        # renders `normalized` — the PRE-translation wire spelling — so the
        # I96 bytes (LEG1–LEG5, the belt) are unchanged BY CONSTRUCTION.
        bound = normalized.transform_keys { |key| self.class.wire_to_kwargs[key.to_s] || key }
        bound[:tool_call] = tool_call if tool_call && execute_accepts_tool_call?
        execute(**bound)
      rescue ArgumentError => e
        # I96 (jetpks/tart#19): a provider shape that cannot bind — a missing
        # required keyword, or an unknown one — raises HERE, before execute's
        # in-body safe_execute rescue and validate_input ever run, and the
        # escape killed the whole session. Consult the I43 seam first (S2) on
        # the raw symbolized arguments minus the +tool_call+ duck: a failure
        # IS the result — dry's canonical `…: is missing` wrapper with the
        # pinned-rule precedence intact. When validation passes (the pure
        # unknown-keyword class) or the name has no registered contract (the
        # KeyError belted away — memory, subagent, contact_supervisor,
        # architect_loop, architect_compact), ONE minted wrapper speaks the
        # binding error as its single failure line, rendered by the seam's
        # own pretty_arguments (S3). Never re-raises; the green path and the
        # present-invalid path (in-body validation on the BOUND kwargs) stay
        # byte-unchanged — pre-dispatch validation was REJECTED (D1): it
        # would re-route those frozen bytes and leave unknown keys crashing.
        received = normalized.reject { |key, _value| key == :tool_call }
        consulted =
          begin
            Schemas::Tools.validate(self.class.pi_name, received)
          rescue KeyError
            nil # a contract-less name: the belt speaks for the seam
          end
        consulted ||
          {error: "Validation failed for tool \"#{self.class.pi_name}\":\n  - #{e.message}\n\n" \
                  "Received arguments:\n#{Schemas::Tools.pretty_arguments(received)}"}
      end

      private

      def execute_accepts_tool_call?
        method(:execute).parameters.any? { |(_kind, param)| param == :tool_call }
      end

      # The I43 input-validation seam — ONE idiom for all seven built-ins:
      # the tool's contract is looked up by wire name ({Schemas::Tools}),
      # keyed off +pi_name+. nil passes; a failure comes back as the
      # {error:} result — the pinned in-tool strings byte-exact where they
      # exist (bash timeout, edit edits), pi's loop-level wrapper shape for
      # the rest. Every execute opens with this inside its safe_execute
      # block, before the runtime work; runtime raises stay raises.
      def validate_input(**arguments)
        # I97 Law 5 — the in-body consult speaks WIRE: the bound kwargs remap
        # through the derived inverse map first, so the present-invalid
        # wrapper prints the BOUND defaults under WIRE names — the I96 pin-4
        # camel bytes stay exact, and grep's payload now reads "ignoreCase"
        # (the declared delta: the wrapper speaks the schema's language).
        wire = arguments.transform_keys { |key| self.class.kwargs_to_wire.fetch(key, key) }
        Schemas::Tools.validate(self.class.pi_name, wire)
      end

      def safe_execute
        yield
      rescue Fast::Completions::CancelledError
        raise
        # I94 E5: ArgumentError stays byte-exact (pi's deliberate
        # contract-raise idiom — every golden error case); every other
        # StandardError is an internal defect and carries the class + first
        # backtrace line, so the model sees WHAT broke and WHERE.
      rescue StandardError => e
        site = e.backtrace&.first
        message = e.is_a?(ArgumentError) ? e.message : "#{e.class}: #{e.message}#{" (at #{site})" if site}"
        {error: message}
      end
    end
  end
end
