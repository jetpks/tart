# frozen_string_literal: true

module Tart
  # I119 env-templates — pi's `$ENV` config-value resolution for the two
  # carried fields pi expands (models.json `providers.<id>.apiKey`, mcp.json
  # `mcpServers.<name>.env.<KEY>` values), resolved AT USE, never at load (the
  # catalog stays byte-untouched). Port of pi
  # packages/coding-agent/src/core/resolve-config-value.ts — the TEMPLATE arm
  # verbatim; the `!command` arm is CUT (owner ruling 2026-11-23): a
  # leading-`!` value is neither executed nor sent.
  #
  # Grammar (parseConfigValueTemplate :28-78): `$VAR` — the name is the
  # longest `[A-Za-z_][A-Za-z0-9_]*` prefix (:66-71); `${VAR}` ONLY when the
  # braced text is a full valid name (:48-64) — `${VAR:-default}` and any
  # other braced text are LITERAL, and an unclosed `${` is a literal `$`
  # (:50-54); `$$` → `$` and `$!` → `!` (:42-46); a `$` before anything else
  # is a literal `$` (:73-74). A value with no `$` resolves to itself.
  #
  # An EMPTY-STRING env value counts as unset (pi :89 — the `||` chain);
  # any unresolved part ⇒ nil (:101-113). The env is the INJECTED hash and
  # nothing else: pi's `process.env` fall-through (:89) serves its own
  # credential-scoped injection; tart's seams inject the process ENV
  # themselves, so one source is observably identical at every seam and a
  # partial hash never leaks the ambient environment into a test.
  module ConfigValue
    class Error < StandardError; end

    # pi :242-247 — the two exact failure strings (singular / plural).
    class UnresolvedError < Error; end

    # The `!command` cut — tart's own named message (the entry's one
    # deviation from pi's :236-238 "from shell command:" string, itemized).
    class CommandConfigValueError < Error; end

    COMMAND_UNSUPPORTED = '"!command" values are not supported — use a "$VAR" or "${VAR}" ' \
      'reference or the <IDENTITY>_API_KEY environment override'

    # JS `$`/`^` without `m` match end/start-of-input only ("FOO\n" fails),
    # so the anchors are \A/\z — never ^/$/\Z (a trailing newline would
    # slip through Ruby's looser anchors; port note, probe-verified).
    NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/ # pi :11 — a FULL valid name
    NAME_PREFIX = /\A[A-Za-z_][A-Za-z0-9_]*/ # pi :12 — the bare-$VAR longest prefix

    module_function

    # pi parseConfigValueReference :80-83: a leading `!` is a command value
    # (nothing else is the form — "$!literal" is the escape, not this).
    def command?(config)
      config.start_with?("!")
    end

    # pi getConfigValueEnvVarNames :121-123 + getTemplateEnvVarNames :92-99:
    # the template's env names — deduped, first-seen order; none for a
    # command value.
    def env_var_names(config)
      return [] if command?(config)

      parse(config).filter_map { |tag, name| name if tag == :env }.uniq
    end

    # pi resolveConfigValueUncached :221-227 minus the command arm: the
    # resolved String, or nil when any name is unset OR empty. A command
    # value answers nil — never runs anything (the cut).
    def resolve(config, env:)
      return nil if command?(config)

      resolve_parts(parse(config), env)
    end

    # pi resolveConfigValueOrThrow :229-251: the resolved String, or raises
    # UnresolvedError with pi's EXACT strings — the MISSING names only
    # (resolved names excluded, :241; one ⇒ "variable" :242-243, more ⇒
    # "variables" :245-247, deduped first-seen) — or the command cut's own
    # CommandConfigValueError.
    def resolve!(config, description, env:)
      value = resolve(config, env:)
      return value unless value.nil?

      raise CommandConfigValueError, "Failed to resolve #{description}: #{COMMAND_UNSUPPORTED}" if command?(config)

      missing = env_var_names(config).reject { |name| env_value(name, env) }
      raise UnresolvedError, "Failed to resolve #{description} from environment variable: #{missing[0]}" if missing.size == 1
      raise UnresolvedError, "Failed to resolve #{description} from environment variables: #{missing.join(', ')}" if missing.size > 1

      # pi :250 — unreachable (a nil resolve ⇒ ≥1 env name, all missing).
      raise UnresolvedError, "Failed to resolve #{description}"
    end

    # The parse (pi parseConfigValueTemplate :28-78): a flat Array of
    # [tag, text] pairs — :literal Strings and :env String names.
    def parse(config)
      parts = []
      index = 0
      while index < config.length
        dollar = config.index("$", index)
        if dollar.nil?
          append_literal(parts, config[index..])
          break
        end
        append_literal(parts, config[index...dollar])
        nxt = config[dollar + 1]
        if nxt == "$" || nxt == "!" # :42-46 — the escapes
          append_literal(parts, nxt)
          index = dollar + 2
        elsif nxt == "{" # :48-64 — the braced form
          close = config.index("}", dollar + 2)
          if close.nil?
            append_literal(parts, "$") # :50-54 — unclosed ${ is a literal $
            index = dollar + 1
          else
            name = config[(dollar + 2)...close]
            if name.match?(NAME)
              parts << [:env, name]
            else
              append_literal(parts, config[dollar..close]) # :60 — the literal braced text
            end
            index = close + 1
          end
        else
          match = config[(dollar + 1)..].match(NAME_PREFIX)
          if match # :66-71 — the longest valid name prefix
            parts << [:env, match[0]]
            index = dollar + 1 + match[0].length
          else
            append_literal(parts, "$") # :73-74 — a $ before anything else
            index = dollar + 1
          end
        end
      end
      parts
    end

    # pi resolveTemplate :101-113 — any unset part voids the whole value.
    def resolve_parts(parts, env)
      parts.each_with_object(+"") do |(tag, value), resolved|
        if tag == :env
          env_value = env_value(value, env)
          return nil if env_value.nil?
          resolved << env_value
        else
          resolved << value
        end
      end
    end

    # pi :89 — `env[name] || undefined`: nil and "" both count as unset.
    def env_value(name, env)
      value = env[name]
      value.nil? || value.empty? ? nil : value
    end

    # pi appendLiteral :18-26 — empty literals are skipped, runs merge.
    def append_literal(parts, value)
      return if value.nil? || value.empty?
      if parts.last&.first == :literal
        parts[parts.size - 1] = [:literal, parts.last[1] + value]
      else
        parts << [:literal, value]
      end
    end
    private_class_method :parse, :resolve_parts, :env_value, :append_literal
  end
end
