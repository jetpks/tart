# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
# The boot-law module rides bin/tart's own require (the one authorized
# bin/tart seam); the unit pins load it directly — the public surface is
# still Tart::UTF8Boot.enforce!.
require_relative "../lib/tart/utf8_boot"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I80 child-encoding-hygiene pin battery (the three frozen laws,
  # driven through the PUBLIC surfaces): the child locale law (manager.rb
  # child_env via spawn_argv_and_env — the subagents_test idiom: a staged
  # Manager + a REAL bin/tart child on the MockLLMServer), the boot UTF-8
  # law (Tart::UTF8Boot.enforce! with save/restore of
  # Encoding.default_external — the law mutates process globals by
  # design), and the byte-exact task-text argv pin. Every test name
  # matches /encoding/ (the frozen child-encoding-units gate filter).
  # Hermetic: staged HOME + closed manager env; the only network is the
  # mock on 127.0.0.1.
  class ChildEncodingTest < Test
    # The Diátaxis-grade payload (Grounds: á é ü ✓ —): compared BYTES, not
    # encodings, so the pin holds whichever tag the boundary carries.
    TASK = "I80 encoding: write the Diátaxis note — résumé ✓ (á é ü)"

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i80-encoding-home-")
      @cwd = Dir.mktmpdir("i80-encoding-cwd-")
      @hooks = Hooks.new
      @managers = []
      @saved_external = Encoding.default_external
      @saved_internal = Encoding.default_internal
    end

    def teardown
      Encoding.default_external = @saved_external
      Encoding.default_internal = @saved_internal
      Subagents.current_manager = nil
      @managers.each(&:shutdown)
      @server.stop
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- Law 1: the child locale law (through the public spawn_argv_and_env) ---

    # The pass-through pin from a POISONED bundler env: LANG + every LC_*
    # ride through verbatim while the I73 scrub still strips every bundler
    # key — the security law holds, the pick list grew only locale keys.
    def test_encoding_child_env_passes_locale_through_a_poisoned_bundler_env
      @server.script([{type: :stream, content: "ok"}])
      poisoned = {
        "PATH" => "/bundle/bin:#{ENV['PATH']}", "HOME" => @home,
        "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url,
        "BUNDLE_GEMFILE" => "/t/Gemfile", "BUNDLER_VERSION" => "4.0.22",
        "BUNDLER_ORIG_PATH" => ENV["PATH"], "BUNDLER_ORIG_BUNDLE_GEMFILE" => ChildEnv::INTENTIONALLY_NIL,
        "RUBYOPT" => "-r/x/y/bundler/setup -w", "BUNDLER_ORIG_RUBYOPT" => ChildEnv::INTENTIONALLY_NIL,
        "LANG" => "en_US.UTF-8", "LC_MESSAGES" => "POSIX"
      }
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: poisoned,
                                       identity: "pi", hooks: @hooks)
      @managers << manager
      run = manager.spawn_run(agent: "worker", task: "t", async: false, timeout_ms: 0, tool_timeout_ms: 0)

      assert_equal :completed, run[:state], "the child boots and completes on the scrubbed env"
      _, env = manager.spawn_argv_and_env(run)
      assert_equal "en_US.UTF-8", env["LANG"], "LANG rides through verbatim (pi parity)"
      assert_equal "POSIX", env["LC_MESSAGES"], "every LC_* rides through verbatim"
      assert_equal ENV["PATH"], env["PATH"], "the PATH pick restored the user's PATH"
      assert env.keys.grep(/\A(BUNDLE_|BUNDLER_ORIG_)/).empty?,
             "zero bundler keys reached the child: #{env.keys.grep(/\A(BUNDLE_|BUNDLER_ORIG_)/).inspect}"
      refute env.key?("RUBYOPT"), "the bundler RUBYOPT poison stayed stripped (the I73 law)"
      %w[LC_CTYPE LC_ALL].each do |key|
        refute env.key?(key), "#{key} must not be invented when LANG is already UTF-8"
      end
    end

    # The floor with NO locale key in the source: LC_CTYPE=en_US.UTF-8,
    # nothing invented for LANG.
    def test_encoding_child_env_floor_sets_lc_ctype_when_no_locale_key_present
      _, env = encoding_env({})
      assert_equal "en_US.UTF-8", env["LC_CTYPE"], "the UTF-8 floor rides LC_CTYPE"
      refute env.key?("LANG"), "LANG is never invented"
      refute env.key?("LC_ALL"), "LC_ALL is never invented when LC_CTYPE carries the floor"
    end

    # A non-UTF-8 LANG masks nothing: LC_CTYPE gets the floor, LANG stays
    # byte-untouched (the pass-through value survives verbatim).
    def test_encoding_child_env_floor_sets_lc_ctype_over_a_non_utf8_lang
      _, env = encoding_env({ "LANG" => "C" })
      assert_equal "en_US.UTF-8", env["LC_CTYPE"]
      assert_equal "C", env["LANG"], "a non-UTF-8 LANG passes through untouched (the floor rides LC_CTYPE)"
      refute env.key?("LC_ALL")
    end

    # A UTF-8 LANG: nothing added or changed (the floor is a no-op).
    def test_encoding_child_env_floor_is_a_noop_for_a_utf8_lang
      _, env = encoding_env({ "LANG" => "en_US.UTF-8" })
      assert_equal "en_US.UTF-8", env["LANG"]
      refute env.key?("LC_CTYPE")
      refute env.key?("LC_ALL")
    end

    # A present non-UTF-8 LC_ALL would mask the LC_CTYPE floor, so LC_ALL
    # is itself overridden.
    def test_encoding_child_env_floor_overrides_a_non_utf8_lc_all
      _, env = encoding_env({ "LC_ALL" => "C", "LANG" => "en_US.UTF-8" })
      assert_equal "en_US.UTF-8", env["LC_ALL"], "a present non-UTF-8 LC_ALL is overridden"
      assert_equal "en_US.UTF-8", env["LANG"], "the pass-through LANG value survives"
      refute env.key?("LC_CTYPE"), "LC_CTYPE is not set when LC_ALL carries the floor"
    end

    # Law 1's argv half: the Diátaxis-grade task text rides argv BYTE-EXACT.
    def test_encoding_spawn_argv_carries_the_task_text_byte_exact
      @server.script([{type: :stream, content: "ok"}])
      manager = new_encoding_manager({ "LANG" => "en_US.UTF-8" })
      run = manager.spawn_run(agent: "worker", task: TASK, async: false, timeout_ms: 0, tool_timeout_ms: 0)

      assert_equal :completed, run[:state]
      argv, = manager.spawn_argv_and_env(run)
      assert_equal TASK.b, argv[3].b, "the task text rides argv byte-exact (a Diátaxis-grade payload)"
    end

    # --- Law 2: the boot UTF-8 law (Tart::UTF8Boot.enforce!, both ways) ---

    # US-ASCII external → UTF_8; BINARY-tagged valid-UTF-8 argv retagged
    # in place, bytes identical; default_internal stays nil.
    def test_encoding_boot_sets_utf8_external_and_retags_valid_utf8_argv
      binary_argv = ["Diátaxis ✓ — résumé".b, "plain-ascii".b.freeze]
      before = binary_argv.map { |e| e.dup.b }
      begin
        Encoding.default_external = Encoding::US_ASCII
        Tart::UTF8Boot.enforce!(argv: binary_argv)
        assert_equal Encoding::UTF_8, Encoding.default_external
        assert_nil Encoding.default_internal, "default_internal stays nil, never touched"
        assert_equal Encoding::UTF_8, binary_argv[0].encoding, "the BINARY-tagged valid-UTF-8 element is retagged"
        assert_equal Encoding::UTF_8, binary_argv[1].encoding,
                     "a FROZEN argv element (ruby 4.0 ARGV) is retagged by slot replacement"
        assert_equal before[0].b, binary_argv[0].b, "the retag moves tags, never bytes"
        assert_equal before[1].b, binary_argv[1].b
      ensure
        Encoding.default_external = @saved_external
      end
    end

    # Invalid-UTF-8 argv bytes are left byte-identical, never mangled (a
    # binary argv stays binary).
    def test_encoding_boot_leaves_invalid_utf8_argv_byte_identical
      element = "\xC3\x28binary\xFF".b
      begin
        Encoding.default_external = Encoding::US_ASCII
        argv = [element, "Diátaxis ✓".b]
        Tart::UTF8Boot.enforce!(argv: argv)
        assert_equal Encoding::ASCII_8BIT, argv[0].encoding, "the invalid-UTF-8 element is untouched"
        assert_equal element.b, argv[0].b, "the invalid-UTF-8 bytes are byte-identical"
        assert_equal Encoding::UTF_8, argv[1].encoding, "the valid-UTF-8 sibling still retags"
      ensure
        Encoding.default_external = @saved_external
      end
    end

    # A UTF-8 external + UTF-8-tagged argv: the law is a no-op (identity).
    def test_encoding_boot_is_a_noop_when_already_utf8
      element = "Diátaxis ✓"
      argv = [element]
      Encoding.default_external = Encoding::UTF_8
      Tart::UTF8Boot.enforce!(argv: argv)
      assert_same element, argv[0], "a UTF-8-tagged argv element is not re-tagged (identity)"
      assert_equal Encoding::UTF_8, Encoding.default_external
    ensure
      Encoding.default_external = @saved_external
    end

    private

    # The staged Manager + one REAL child spawn (the subagents_test
    # idiom): the run record feeds the public spawn_argv_and_env.
    def encoding_env(locale)
      @server.script([{type: :stream, content: "ok"}])
      manager = new_encoding_manager(locale)
      run = manager.spawn_run(agent: "worker", task: "t", async: false, timeout_ms: 0, tool_timeout_ms: 0)

      assert_equal :completed, run[:state], "the child boots and completes"
      manager.spawn_argv_and_env(run)
    end

    def new_encoding_manager(locale)
      env = { "PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key",
              "PI_API_BASE" => @server.url }.merge(locale)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: env,
                                       identity: "pi", hooks: @hooks)
      @managers << manager
      manager
    end
  end
end
