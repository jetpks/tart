# frozen_string_literal: true

module Tart
  # I73 child-env-scrub — THE LAW (architecture/I73-child-env-scrub.md
  # §THE LAW): a self-describing scrub of bundler's exported environment,
  # applied at every env-composing child-spawn seam (the bash tool's two
  # arms, the subagent child, the MCP stdio child). Tart launched via
  # `bundle exec` exports bundler's environment into every spawned child,
  # and any rubygems CLI outside tart's bundle dies in activation there —
  # the law restores the user's shell env so children see it regardless of
  # how tart itself was launched.
  #
  # No hardcoded bundler key list (lists rot across bundler versions):
  # bundler's EnvironmentPreserver records every key it touches as
  # BUNDLER_ORIG_<key> BEFORE mutating it (environment_preserver.rb
  # BUNDLER_KEYS via shared_helpers.rb#set_env, the only writer), so the
  # records are discovered from the env itself — and an env with no
  # records and no bundler additions scrubs to itself (the no-op when
  # tart is launched clean).
  module ChildEnv
    # bundler/environment_preserver.rb INTENTIONALLY_NIL — the one literal
    # the law must know: a record carrying it means the pre-exec user
    # value was nil, so the record DELETES its target.
    INTENTIONALLY_NIL = "BUNDLER_ENVIRONMENT_PRESERVER_INTENTIONALLY_NIL"

    module_function

    # The scrub, in the frozen order:
    #
    # 1. ORIG restore (records authoritative) — every BUNDLER_ORIG_X key
    #    is dropped and applied to its target X; an INTENTIONALLY_NIL
    #    record deletes the target, any other record value restores it.
    #    A record wins even where a belt would have kept entries.
    # 2. RUBYOPT belt — if RUBYOPT survives step 1 (hand-exported
    #    poison), strip exactly the tokens bundler's set_rubyopt adds —
    #    `-r<abs path ending in bundler/setup>` and the `-rbundler/setup`
    #    fallback — keeping every other token (a rig render-perf-probe
    #    require rides through untouched); delete the key if nothing
    #    survives.
    # 3. RUBYLIB belt — if RUBYLIB survives step 1, strip the entries
    #    bundler's set_rubylib adds (dirs containing bundler/setup.rb);
    #    keep every other entry; delete the key if nothing survives.
    #
    # Never mutates its argument: a copy in, a new hash out (Hash#to_h
    # returns self — the scrub copies).
    def scrub(env)
      out = env.dup
      out.keys.grep(/\ABUNDLER_ORIG_/).each do |orig|
        recorded = out.delete(orig)
        target = orig.sub(/\ABUNDLER_ORIG_/, "")
        if recorded == INTENTIONALLY_NIL
          out.delete(target)
        else
          out[target] = recorded
        end
      end
      if (value = out["RUBYOPT"])
        tokens = value.split(/\s+/).reject do |token|
          token =~ /\A-r.*bundler\/setup\z/ || token == "-rbundler/setup"
        end
        tokens.empty? ? out.delete("RUBYOPT") : out["RUBYOPT"] = tokens.join(" ")
      end
      if (value = out["RUBYLIB"])
        entries = value.split(File::PATH_SEPARATOR).reject do |entry|
          File.exist?(File.join(entry, "bundler", "setup.rb"))
        end
        entries.empty? ? out.delete("RUBYLIB") : out["RUBYLIB"] = entries.join(File::PATH_SEPARATOR)
      end
      out
    end
  end
end