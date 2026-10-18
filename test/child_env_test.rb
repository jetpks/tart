# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Tart
  # THE LAW, both ways (I73 AC1): Tart::ChildEnv.scrub — a poisoned env
  # (bundler's own BUNDLER_ORIG_* record shape) yields the recorded
  # user-shell env; the belt arms strip exactly bundler's RUBYOPT/RUBYLIB
  # additions while every other token/entry rides through; a clean env is
  # an identity; the argument is never mutated.
  class ChildEnvTest < Test
    NIL = ChildEnv::INTENTIONALLY_NIL

    # The measured poison chain shape (the bundler 4.0.22 preserver's
    # record-for-every-set-key contract), plus one user var to ride.
    POISONED = {
      "BUNDLE_GEMFILE" => "/t/Gemfile", "BUNDLE_LOCKFILE" => "/t/Gemfile.lock",
      "BUNDLE_BIN_PATH" => "/b/exe/bundle", "BUNDLER_VERSION" => "4.0.22",
      "BUNDLER_SETUP" => "/s/bundler/setup",
      "RUBYOPT" => "-r/s/bundler/setup -w", "RUBYLIB" => "/s",
      "GEM_HOME" => "/gems", "GEM_PATH" => "/gp", "MANPATH" => "/m",
      "RB_USER_INSTALL" => "1", "PATH" => "/bundle/bin:/usr/bin:/bin",
      "BUNDLER_ORIG_BUNDLE_GEMFILE" => NIL, "BUNDLER_ORIG_BUNDLE_LOCKFILE" => NIL,
      "BUNDLER_ORIG_BUNDLE_BIN_PATH" => NIL, "BUNDLER_ORIG_BUNDLER_VERSION" => NIL,
      "BUNDLER_ORIG_BUNDLER_SETUP" => NIL, "BUNDLER_ORIG_GEM_HOME" => NIL,
      "BUNDLER_ORIG_GEM_PATH" => NIL, "BUNDLER_ORIG_MANPATH" => NIL,
      "BUNDLER_ORIG_RB_USER_INSTALL" => NIL, "BUNDLER_ORIG_PATH" => "/usr/bin:/bin",
      "BUNDLER_ORIG_RUBYOPT" => "-w", "BUNDLER_ORIG_RUBYLIB" => NIL,
      "USER_VAR" => "keep-me"
    }.freeze

    def test_child_env_scrub_restores_the_recorded_user_shell_env
      out = ChildEnv.scrub(POISONED)

      # Every bundler-set key lands on its record: NIL records delete
      # their target (the pre-exec user value was nil), value records
      # restore (PATH back to the user's shell PATH, RUBYOPT to "-w").
      %w[BUNDLE_GEMFILE BUNDLE_LOCKFILE BUNDLE_BIN_PATH BUNDLER_VERSION BUNDLER_SETUP
         GEM_HOME GEM_PATH MANPATH RB_USER_INSTALL RUBYLIB].each do |key|
        refute out.key?(key), "poison key #{key} survived: #{out[key].inspect}"
      end
      assert_equal "/usr/bin:/bin", out["PATH"], "PATH restored to the ORIG record"
      assert_equal "-w", out["RUBYOPT"], "RUBYOPT restored to the user original"
      assert_empty out.keys.grep(/\ABUNDLER_ORIG_/), "zero ORIG residue"
      assert_equal "keep-me", out["USER_VAR"], "user keys are preserved"
    end

    def test_child_env_scrub_does_not_mutate_its_argument
      input = POISONED.dup
      frozen = input.dup

      ChildEnv.scrub(input)

      assert_equal frozen, input, "the scrub MUTATED its argument"
    end

    def test_child_env_nil_record_deletes_its_target_and_the_belt_never_overrides
      Dir.mktmpdir("i73-child-env-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "bundler"))
        FileUtils.touch(File.join(dir, "bundler", "setup.rb"))
        env = {"RUBYLIB" => [dir, "/user/lib"].join(File::PATH_SEPARATOR),
               "BUNDLER_ORIG_RUBYLIB" => NIL}

        out = ChildEnv.scrub(env)

        refute out.key?("RUBYLIB"),
               "a NIL ORIG record must DELETE RUBYLIB (records are authoritative, " \
               "the belt never overrides them): #{out["RUBYLIB"].inspect}"
      end
    end

    def test_child_env_rubyopt_belt_strips_only_bundler_tokens
      out = ChildEnv.scrub({"RUBYOPT" => "-r/x/y/bundler/setup -w -rother", "USER_VAR" => "keep-me"})

      assert_equal "-w -rother", out["RUBYOPT"], "the bundler setup token stripped, the rest kept"
      assert_equal "keep-me", out["USER_VAR"]

      # the no-path fallback form bundler's set_rubyopt uses when the
      # setup path has spaces.
      assert_equal "-w", ChildEnv.scrub({"RUBYOPT" => "-rbundler/setup -w"})["RUBYOPT"]
    end

    def test_child_env_rubyopt_belt_deletes_the_key_when_nothing_survives
      out = ChildEnv.scrub({"RUBYOPT" => "-r/x/y/bundler/setup"})

      refute out.key?("RUBYOPT"), "nothing survives: the key is deleted, never left empty"
    end

    def test_child_env_rubylib_belt_strips_the_bundler_lib_dir
      Dir.mktmpdir("i73-child-env-") do |dir|
        FileUtils.mkdir_p(File.join(dir, "bundler"))
        FileUtils.touch(File.join(dir, "bundler", "setup.rb"))
        env = {"RUBYLIB" => [dir, "/user/lib"].join(File::PATH_SEPARATOR)}

        out = ChildEnv.scrub(env)

        assert_equal "/user/lib", out["RUBYLIB"],
                     "the belt-with-no-record still strips the bundler lib dir, keeps the user entries"
      end
    end

    def test_child_env_restored_rubyopt_rides_the_belt_untouched
      # The record-authoritative RUBYOPT: the user's original value is
      # restored in step 1 and carries no bundler tokens — the belt on
      # the surviving value is a no-op, never a re-deletion.
      out = ChildEnv.scrub({"RUBYOPT" => "-r/s/bundler/setup -Esj",
                            "BUNDLER_ORIG_RUBYOPT" => "-Esj"})

      assert_equal "-Esj", out["RUBYOPT"]
    end

    def test_child_env_clean_env_is_an_identity
      clean = {"PATH" => "/usr/bin:/bin", "HOME" => "/h", "USER_VAR" => "v"}

      assert_equal clean, ChildEnv.scrub(clean), "a clean env is a no-op"
    end

    def test_child_env_empty_env_is_an_identity
      assert_empty ChildEnv.scrub({})
    end
  end
end