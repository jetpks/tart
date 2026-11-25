# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # I119 AC1 — Tart::ConfigValue, the pure resolver: pi's template grammar
  # (resolve-config-value.ts parseConfigValueTemplate :28-78; the test table
  # ported from test/resolve-config-value.test.ts template-arm cases + the
  # parser-letter edges), the empty-string-is-unset law (:89), the exact
  # failure strings (:242-247), and the `!command` cut (owner ruling
  # 2026-11-23). Every case asserts on an INJECTED env hash.
  class ConfigValueTest < Test
    ENV_HASH = {"TEST_CONFIG_LEFT" => "left", "TEST_CONFIG_RIGHT" => "right",
      "EMPTY" => "", "DASH" => "a-b", "L" => "left", "E" => "", "E2" => ""}.freeze

    def setup
      @dir = Dir.mktmpdir("t119-units-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # pi's own table (resolve-config-value.test.ts:27-40), the template arm.
    def test_pi_table_literals_templates_and_escapes
      assert_equal "literal-key", ConfigValue.resolve("literal-key", env: ENV_HASH)
      assert_equal "left", ConfigValue.resolve("$TEST_CONFIG_LEFT", env: ENV_HASH)
      assert_equal "left_right", ConfigValue.resolve("${TEST_CONFIG_LEFT}_$TEST_CONFIG_RIGHT", env: ENV_HASH)
      assert_equal "$TEST_CONFIG_LEFT", ConfigValue.resolve("$$TEST_CONFIG_LEFT", env: ENV_HASH)
      assert_equal "!literal-right", ConfigValue.resolve("$!literal-$TEST_CONFIG_RIGHT", env: ENV_HASH)
    end

    # parseConfigValueTemplate :48-64 — braced names resolve ONLY when the
    # braced text is a full valid name; everything else is literal.
    def test_braced_form_resolves_only_a_full_valid_name
      assert_equal "left", ConfigValue.resolve("${TEST_CONFIG_LEFT}", env: ENV_HASH)
      assert_equal "a-b", ConfigValue.resolve("${DASH}", env: ENV_HASH)
      assert_equal "${TEST_CONFIG_LEFT:-x}", ConfigValue.resolve("${TEST_CONFIG_LEFT:-x}", env: ENV_HASH), "no default form"
      assert_equal "${1DIGIT}", ConfigValue.resolve("${1DIGIT}", env: ENV_HASH)
      assert_equal "${TEST_CONFIG_LEFT }", ConfigValue.resolve("${TEST_CONFIG_LEFT }", env: ENV_HASH)
      assert_equal "${ TEST_CONFIG_LEFT}", ConfigValue.resolve("${ TEST_CONFIG_LEFT}", env: ENV_HASH)
      assert_equal "${}", ConfigValue.resolve("${}", env: ENV_HASH)
      assert_equal "${ }", ConfigValue.resolve("${ }", env: ENV_HASH)
      assert_equal "left}", ConfigValue.resolve("${TEST_CONFIG_LEFT}}", env: ENV_HASH)
      assert_empty ConfigValue.env_var_names("${TEST_CONFIG_LEFT:-x}"), "a literal braced form names nothing"
    end

    # :50-54, :42-46, :73-74 — unclosed `${` is a literal `$`; `$$`/`$!`
    # escape; a `$` before anything else is a literal `$`.
    def test_unclosed_escapes_and_stray_dollars_are_literal
      assert_equal "${TEST_CONFIG_LEFT", ConfigValue.resolve("${TEST_CONFIG_LEFT", env: ENV_HASH)
      assert_equal "$", ConfigValue.resolve("$", env: ENV_HASH)
      assert_equal "$", ConfigValue.resolve("$$", env: ENV_HASH)
      assert_equal "!", ConfigValue.resolve("$!", env: ENV_HASH)
      assert_equal "$!", ConfigValue.resolve("$$!", env: ENV_HASH)
      assert_equal "a$", ConfigValue.resolve("a$", env: ENV_HASH)
      assert_equal "$ ", ConfigValue.resolve("$ ", env: ENV_HASH)
      assert_equal "$1", ConfigValue.resolve("$1", env: ENV_HASH), "a digit cannot start a name"
      assert_equal "$-", ConfigValue.resolve("$-", env: ENV_HASH)
      assert_equal "$ TEST_CONFIG_LEFT", ConfigValue.resolve("$ TEST_CONFIG_LEFT", env: ENV_HASH)
      assert_equal "left $ $", ConfigValue.resolve("$TEST_CONFIG_LEFT $$ $$", env: ENV_HASH)
      assert_equal "", ConfigValue.resolve("", env: ENV_HASH), "an empty value resolves to itself"
    end

    # :66-71 — the bare form takes the LONGEST valid name prefix.
    def test_bare_form_takes_the_longest_valid_name_prefix
      assert_equal "leftleft", ConfigValue.resolve("${TEST_CONFIG_LEFT}${TEST_CONFIG_LEFT}", env: ENV_HASH)
      assert_equal "leftright", ConfigValue.resolve("$TEST_CONFIG_LEFT$TEST_CONFIG_RIGHT", env: ENV_HASH)
      assert_equal "a-bleft", ConfigValue.resolve("$DASH$TEST_CONFIG_LEFT", env: ENV_HASH)
      assert_equal "left$", ConfigValue.resolve("$TEST_CONFIG_LEFT$", env: ENV_HASH)
      assert_nil ConfigValue.resolve("$TEST_CONFIG_LEFT_ID", env: ENV_HASH), "the whole run is the name"
      assert_nil ConfigValue.resolve("$TE ST", env: ENV_HASH), "the name ends at the space"
      assert_nil ConfigValue.resolve("a$b", env: ENV_HASH), "a letter can follow a literal"
    end

    # :89 — `env[name] || undefined`: an EMPTY-STRING value counts as unset;
    # any unresolved part ⇒ nil (:101-113). Names are case-sensitive.
    def test_empty_string_counts_as_unset_and_any_missing_part_fails_the_value
      assert_nil ConfigValue.resolve("$EMPTY", env: ENV_HASH)
      assert_nil ConfigValue.resolve("${EMPTY}", env: ENV_HASH)
      assert_nil ConfigValue.resolve("$TEST_CONFIG_LEFT$EMPTY", env: ENV_HASH)
      assert_nil ConfigValue.resolve("$MISSING", env: ENV_HASH)
      assert_nil ConfigValue.resolve("$TEST_CONFIG_LEFT$MISSING", env: ENV_HASH)
      assert_nil ConfigValue.resolve("$MISSING$ALSO_MISSING", env: ENV_HASH)
      assert_nil ConfigValue.resolve("$Test_Config_Left", env: ENV_HASH), "case-sensitive"
      assert_nil ConfigValue.resolve("${test_config_left}", env: ENV_HASH)
    end

    # The injected hash is the ONLY source (pi's :89 process.env fall-through
    # serves its own credential-scoped injection; tart's seams inject ENV).
    def test_the_injected_hash_is_the_only_source
      name = "T119_UNIT_PROBE_#{object_id}"
      ENV[name] = "ambient"
      begin
        assert_nil ConfigValue.resolve("$#{name}", env: {}), "the ambient process env never leaks through a partial hash"
        assert_equal "scoped", ConfigValue.resolve("$#{name}", env: {name => "scoped"}), "the injected value wins"
      ensure
        ENV.delete(name)
      end
    end

    # :92-99 + :121-123 — deduped, first-seen order, STRING names; none for
    # escapes or a command value.
    def test_env_var_names_are_deduped_first_seen
      assert_equal %w[TEST_CONFIG_LEFT TEST_CONFIG_RIGHT], ConfigValue.env_var_names("$TEST_CONFIG_LEFT$TEST_CONFIG_RIGHT$TEST_CONFIG_LEFT")
      assert_equal %w[MISSING ALSO MISSING2], ConfigValue.env_var_names("$MISSING$ALSO$MISSING$MISSING2")
      assert_empty ConfigValue.env_var_names("$$TEST_CONFIG_LEFT")
      assert_empty ConfigValue.env_var_names("!$TEST_CONFIG_LEFT"), "a command value names nothing"
    end

    # :242-247 — pi's exact strings: the MISSING names only, deduped,
    # first-seen; one ⇒ "variable", more ⇒ "variables".
    def test_resolve_bang_raises_pi_s_exact_strings
      error = assert_raises(ConfigValue::UnresolvedError) do
        ConfigValue.resolve!("$MISSING", 'API key for provider "fireworks"', env: ENV_HASH)
      end
      assert_equal 'Failed to resolve API key for provider "fireworks" from environment variable: MISSING', error.message

      error = assert_raises(ConfigValue::UnresolvedError) do
        ConfigValue.resolve!("$MISSING$ALSO_MISSING$MISSING", 'API key for provider "fireworks"', env: ENV_HASH)
      end
      assert_equal 'Failed to resolve API key for provider "fireworks" from environment variables: MISSING, ALSO_MISSING', error.message

      error = assert_raises(ConfigValue::UnresolvedError) do
        ConfigValue.resolve!("$L$MISSING", 'API key for provider "fireworks"', env: ENV_HASH)
      end
      assert_equal 'Failed to resolve API key for provider "fireworks" from environment variable: MISSING', error.message, "resolved names are excluded"

      error = assert_raises(ConfigValue::UnresolvedError) do
        ConfigValue.resolve!("$E$E2", 'MCP server "s" env "K"', env: ENV_HASH)
      end
      assert_equal 'Failed to resolve MCP server "s" env "K" from environment variables: E, E2', error.message, "empty counts as missing"

      assert_kind_of ConfigValue::Error, error, "one rescue family"
      assert_equal "literal", ConfigValue.resolve!("literal", "whatever", env: ENV_HASH)
      assert_equal "", ConfigValue.resolve!("", "whatever", env: ENV_HASH)
    end

    # The `!command` cut (owner ruling 2026-11-23): never executed, never
    # sent — `resolve` answers nil, `resolve!` raises tart's named message,
    # the canary stays uncreated.
    def test_command_values_are_never_executed_and_fail_by_name
      canary = File.join(@dir, "canary")
      assert ConfigValue.command?("!touch #{canary}")
      refute ConfigValue.command?("$HOME")
      refute ConfigValue.command?("$!literal"), "the escape is not the form"

      assert_nil ConfigValue.resolve("!touch #{canary}", env: ENV_HASH)
      refute File.exist?(canary), "resolve never executes"

      error = assert_raises(ConfigValue::CommandConfigValueError) do
        ConfigValue.resolve!("!touch #{canary}", 'API key for provider "fireworks"', env: ENV_HASH)
      end
      assert_equal 'Failed to resolve API key for provider "fireworks": "!command" values are not supported — ' \
        'use a "$VAR" or "${VAR}" reference or the <IDENTITY>_API_KEY environment override', error.message
      assert_kind_of ConfigValue::Error, error
      refute File.exist?(canary), "resolve! never executes"
    end
  end
end
