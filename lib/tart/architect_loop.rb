# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "models"
require_relative "settings"
require_relative "tools/architect_loop"
require_relative "tools/architect_compact"

module Tart
  # The architect loop, driven by the architect session itself (I95 — the
  # port of jetpks/pi-extensions architect-loop.ts + builder-guard.ts):
  # layered architect.yaml role routing, one generated role agent file per
  # role under <spaceRoot>/.tart/agents/ (the I49 project tier — tart does
  # NOT read or write .pi/agents anywhere, owner ruling 3), loud
  # spawn-contract validation against tart's model catalog, the builder
  # guard on the I47 tool_call channel, and driver mode on the launching
  # session via two surfaces sharing one code path: the /loop user command
  # (for humans) and the architect_loop tool (for architect sessions that
  # own the launch end-to-end). The driver playbook installs mid-turn; the
  # architect_compact tool schedules the playbook as the compaction's
  # customInstructions (A-Law 7 — the no-abort port scheduling).
  #
  # House shape: the Memory/Herdr register idiom (A-Law 1) — registered
  # ONCE from the INTERACTIVE boot beside the Memory/Herdr lines, BEFORE
  # build_tools so the tools merge into the loadout; gated by the
  # "architect_loop" settings row / <IDENTITY>_ARCHITECT_LOOP env tier,
  # DEFAULT ON since the I121 flip (the I70 subagents precedent; the
  # opt-out is a settings row {"architect_loop": false} or any non-on env
  # value). The print boot never registers — driver mode is the
  # launching interactive session's concept. Module state is the one
  # installed driver playbook (or nil): reset at every session_start —
  # driver mode is never inherited. NO threads of its own: everything
  # rides the existing channels/fibers (A-Law 1's threads-budget law).
  module ArchitectLoop
    # Config/parse failures — the loud `fail` shape's carrier (pi throws
    # plain Errors; the port names them for the surfaces' rescues).
    Error = Class.new(StandardError)

    # pi RoleName (architect-loop.ts:25).
    ROLE_NAMES = %w[architect spec builder judge narrator].freeze

    # Roles that become generated agent files; `architect` routes the
    # human's own session (no file).
    AGENT_ROLES = {
      "spec" => "architect-spec",
      "builder" => "architect-builder",
      "judge" => "architect-judge",
      "narrator" => "architect-narrator"
    }.freeze

    # pi ROLE_TOOLS (:66-72) with the ONE tart re-expression (A-Law 3): the
    # builder's pi web tools re-express to tart's universe names
    # (web_search, web_fetch — both in Schemas::Subagents
    # ::ProfileFields::TOOLS_UNIVERSE); every other name already exists.
    ROLE_TOOLS = {
      "spec" => %w[read grep find ls bash edit write],
      "builder" => %w[read grep find ls bash edit write web_search web_fetch],
      # Reads its facts, writes one new file — no bash, no edits, no children of its own.
      "judge" => %w[read grep find ls bash edit write],
      "narrator" => %w[read grep find ls write]
    }.freeze

    # pi ROLE_DESCRIPTIONS (:45-50), carried verbatim.
    ROLE_DESCRIPTIONS = {
      "spec" => "Writes one iteration's Grounds, Specification, and Acceptance Criteria; rehearses; freezes; reports lane prompt paths.",
      "builder" => "Implements one architect lane inside its worktree under lane discipline; raw-results report; never commits.",
      "judge" => "Judges one iteration cold: gate, per-AC verdicts, PHASE 0 rulings, then integrate or kill.",
      "narrator" => "Writes one prose context refresh to notes/narrative-*.md at verdict-landed, exception, or plan-complete — for a human whose context has gone stale; writes nothing else."
    }.freeze

    # pi ROLE_PLAYBOOKS (:68-71 region), carried verbatim (they are already
    # harness-agnostic: `architect section`, `git log`, scratch reports).
    ROLE_PLAYBOOKS = {
      "spec" => <<~'SPEC'.chomp,
        You are architect-spec. You produce the specification for ONE iteration of a space-architect plan; the task names the iteration.

        Ground first: read the space's ARCHITECT.md, its BRIEF if present, the architecture/ iteration entry, the repo docs the entry references, and the latest notes/spec-digest-*.md — the previous spec's handoff (verification commands, repo seams, conventions, open unknowns).

        Produce — via `architect section` commands and scratch files (never edit architecture/ files directly; the CLI owns them):
        - Grounds: what is already decided, with citations.
        - Specification: the iteration's contract, lane by lane.
        - Acceptance Criteria: frozen, property-level, each independently judgeable.

        Then run `architect rehearse` and address every finding, rehearsing again after each fix. Freeze only with a fresh rehearsal stamp — never --skip-rehearse.

        Record Builder Prompt provenance for every lane: the exact scratch path each lane's prompt was assembled from, and what was copied where.

        You never provision and never dispatch builders — the session driving the loop owns lanes and launches. Your digest records facts and conventions for the next spec, never dispatch or launch mechanics as house rules.

        Close by writing notes/spec-digest-<UTC timestamp>.md — the handoff for the next spec: the verification commands actually used (exact, tested), the repo seams this iteration touched or discovered, house conventions the next spec must honor, decisions taken with one-line reasons, and known unknowns. Facts only, no narrative.

        Your final report states: the iteration name, each lane's name with its scratch prompt path, the rehearsal verdict vector, the digest path, and any open questions for the judge.
      SPEC
      "builder" => <<~'BUILDER'.chomp,
        You are architect-builder: one lane, one task, from the prompt file you were given. Read it before anything else.

        PHASE 0 — before any code, reply with your plan and EVERY disagreement you have with the task spec, each with reasons citing real files. Silent compliance is a failure; so is a silent scope addition. If you have no disagreements, state what you checked before concluding the spec is sound.

        Treat the task's named shared contracts and the repo's existing public interfaces as frozen — do not change them. Build ONLY the declared touch set. Write idiomatic, house-consistent code: read the neighboring files and match their conventions (plain functions, why-comments, node builtins, no build step). Tests stay terse and exercise public behavior; no mocks of anything you own. No placeholders: search before implementing, full implementations only.

        Never commit and never run any git write command (commit, add, branch, reset, checkout) — the judge verifies `git log <base>..` is empty. Give every long command an explicit timeout; run nothing in the background.

        Write your report to the absolute scratch path the task names: raw results only (tables, numbers, verbatim command output) — no interpretation, no verdicts. End the report with exactly one status line:
        STATUS: COMPLETE | COMPLETE_WITH_CONCERNS (list them) | BLOCKED (exact blocker + what you tried)
      BUILDER
      "judge" => <<~'JUDGE'.chomp,
        You are architect-judge. You judge ONE iteration of a space-architect plan, in a fresh session. You never graded this work as a builder, and you never relax a criterion.

        Mechanical post-flight first, by command, not by reading prose:
        - `architect verify`
        - `git diff <freeze-sha> HEAD -- <iteration file>` — frozen regions must be untouched.
        - `git -C <worktree> log <base>..` — must be empty; lanes commit nothing.

        Transcribe `architect evidence`. Run `architect gate` cold. Then read the actual diff against the Specification's intent.

        Rule on every PHASE 0 disagreement the builders raised: ACCEPT, REJECT, or MODIFY, each with one line of reasoning. Score every acceptance criterion PASS, FAIL, or INVALID (INVALID = the evidence cannot reach the criterion).

        Then run `architect verdict continue|kill`, `architect integrate --lanes <passing>` with teardown, and update the ARCHITECT.md index.
      JUDGE
      "narrator" => <<~'NARRATOR'.chomp
        You are architect-narrator: one spawn, one narration file — a prose context refresh the human reads to catch up on a detached loop, written for a reader whose mental context has gone stale. The task names the kind (verdict-landed | exception | plan-complete), the iteration id, and the UTC timestamp for the filename.

        Read before writing: the space's BRIEF (when present), ARCHITECT.md's TL;DR and its iteration index, the plan file under notes/plan-, this iteration's architecture/ file, and the last one or two notes/narrative-*.md. Read every path a fact cites before citing it — never cite a path you have not read.

        Write exactly one file: notes/narrative-<ts>-<kind>.md, <ts> the task's UTC timestamp in `date -u +%Y%m%dT%H%M%SZ` form. First line an H1 of ~80 characters or fewer that works as an email subject — space, iteration, kind, timestamp.

        The body is prose you compose — full sentences and paragraphs, not a fixed section skeleton: situate the project (its purpose and arc, from BRIEF/ARCHITECT), place this iteration in that arc, say what happened and what it means (the verdict and what landed, in your own words), assess whether the work is on course against the plan's intent, and close with what's next. Name file paths the human can open; never transcribe STATUS lines, run ids, or gate vectors into the narration. Report what the judge ruled — never a verdict on the verdict, never advice.

        Reply with the file's path. You never edit anything else, never write into architecture/, never commit.
      NARRATOR
    }.freeze

    # pi RETIRED_AGENT_FILES — the generation pass self-cleans these out of
    # the agents dir (a stale pre-collapse architect-coordinator.md).
    RETIRED_AGENT_FILES = ["architect-coordinator.md"].freeze

    # pi's thinking-level ladder is tart's own (settings.rb THINKING_LEVELS
    # — the identical vocabulary; a ":level" suffix only counts when it
    # names one of these, so a model id that merely contains a colon keeps
    # working).
    THINKING_LEVELS = Settings::THINKING_LEVELS

    # The plan reference for a launch with no plan file; the plan text
    # rides verbatim in the playbook (pi INLINE_PLAN_REF).
    INLINE_PLAN_REF = "inline plan text"

    # The fix for the no-config case, appended to every "no architect.yaml
    # found" error (pi INIT_HINT — names the architect CLI, harness-agnostic).
    INIT_HINT = "Create one: `architect routing init` (beside space.yaml) or `architect routing init --global` (~/.config/space-architect/architect.yaml)."

    # The /loop command's description (pi registerCommand :599-605,
    # carried verbatim).
    LOOP_COMMAND_DESCRIPTION = "Enter driver mode on a plan: installs the driver playbook — driving starts this turn (no entry compaction)"

    # --- builder-guard.ts constants (the guard law, ported verbatim) ---

    # Git subcommands that mutate repository state. Reads (log, diff, show, …)
    # stay allowed — only the write verbs are denied.
    GIT_WRITE_VERBS = %w[
      commit push pull reset merge rebase checkout switch branch tag
      cherry-pick revert stash worktree clean restore rm mv am apply
    ].freeze

    # Global flags that consume a following value, when locating the
    # subcommand — `git -C <path> commit` must classify as commit (flags sit
    # between `git` and the subcommand, so an adjacency pattern misses it).
    GIT_VALUE_FLAGS = %w[-C -c].freeze

    # The `fail` sentinel: pi renders a missing value as "nothing"
    # (got === undefined); YAML's empty value arrives as nil here.
    MISSING = Object.new.freeze

    # The one installed driver playbook (or nil while not driving): module
    # state captured at launch — every later architect_compact carries it as
    # the compaction's keep-essentials. Reset at session_start — a fresh or
    # resumed session drives only after a launch installs the playbook. A
    # single reference cell (GVL-atomic assignment; no torn reads) written
    # by the installing surface and read by the compaction seam.
    class << self
      attr_reader :driver_playbook_text
    end

    module_function

    # The boot gate (A-Law 1, the subagents gate's exact idiom post-I121):
    # the resolved settings row "architect_loop" or the <IDENTITY>
    # _ARCHITECT_LOOP env tier through Settings.resolve_setting — the
    # DEFAULTS/RESOLUTION_ENV registries own the env > file > default
    # ladder (DEFAULT ON since the I121 flip, the I70 subagents precedent);
    # the on spellings are true/"true"/"1", every other value ("0",
    # "false", "on", …) opts out. The I95 module-local ladder moved into
    # settings.rb with the flip (its frozen touch-set exclusion ended);
    # the bin/tart seat helper delegates here, byte-unchanged.
    def enabled?(settings, identity: Identity::DEFAULT, env: ENV)
      resolved = Settings.resolve_setting("architect_loop", settings, identity: identity, env: env)
      resolved == true || resolved == "true" || resolved == "1"
    end

    # --- config resolution (the resolveConfig port, tart-shaped) ---

    # Env override for the global routing file, mirroring pi's
    # SPACE_ARCHITECT_GLOBAL_CONFIG (tests pin it).
    def global_config_file(env = ENV)
      env["SPACE_ARCHITECT_GLOBAL_CONFIG"] ||
        File.join(Dir.home, ".config", "space-architect", "architect.yaml")
    end

    # Walk up from start_dir to the filesystem root; a space config is an
    # architect.yaml co-located with space.yaml. An architect.yaml without
    # space.yaml is never a config, so stray files along the way are ignored.
    def find_space_root(start_dir)
      dir = File.expand_path(start_dir)
      loop do
        return dir if File.exist?(File.join(dir, "space.yaml")) && File.exist?(File.join(dir, "architect.yaml"))

        parent = File.dirname(dir)
        return nil if parent == dir

        dir = parent
      end
    end

    # pi's `fail` (:109-113): every parse failure names the file, the key,
    # and the expectation — nothing degrades silently.
    def parse_fail(file, key, expected, got = MISSING)
      found = if got.equal?(MISSING)
        "nothing"
      elsif got.is_a?(String)
        got.inspect
      else
        got.to_s
      end
      raise Error, "architect.yaml (#{file}): #{key} — expected #{expected}, got #{found}"
    end

    # Parse and validate one architect.yaml; every failure names the file,
    # the key, and the expectation. Unknown role keys (a retired
    # `coordinator`, a typo) are tolerated and collected, never validated —
    # the entry is ignored whole (resolve_config merges the sets and each
    # surface invocation informs once).
    def parse_architect_yaml(text, file)
      raw = begin
        YAML.safe_load(text, aliases: true)
      rescue Psych::Exception => e
        raise Error, "architect.yaml (#{file}): malformed YAML — #{e.message}"
      end
      parse_fail(file, "document", "a mapping with `version` and `roles`") unless raw.is_a?(Hash)
      parse_fail(file, "version", "1", raw["version"]) unless raw["version"] == 1

      roles = raw["roles"]
      parse_fail(file, "roles", "a map of #{ROLE_NAMES.join("|")}") unless roles.is_a?(Hash)

      parsed = {}
      unknown_roles = []
      roles.each do |name, value|
        name = name.to_s
        unless ROLE_NAMES.include?(name)
          unknown_roles << name
          next
        end
        parse_fail(file, "roles.#{name}", "{ model, thinking? }") unless value.is_a?(Hash)
        value.each_key do |key|
          parse_fail(file, "roles.#{name}.#{key}", "model or thinking") unless key == "model" || key == "thinking"
        end
        model = value["model"]
        parse_fail(file, "roles.#{name}.model", '"provider/model-id[:thinking]"', model) if !model.is_a?(String) || model.strip.empty?
        thinking = value["thinking"]
        unless thinking.nil?
          # Membership is checked after trim (like the model, ` high ` is the
          # valid `high`); a typo'd level would otherwise be silently dropped
          # by the spawn routing.
          unless thinking.is_a?(String) && !thinking.strip.empty?
            parse_fail(file, "roles.#{name}.thinking", "a thinking level string", thinking)
          end
          thinking = thinking.strip
          unless THINKING_LEVELS.include?(thinking)
            parse_fail(file, "roles.#{name}.thinking", "a thinking level (#{THINKING_LEVELS.join("|")})", thinking)
          end
        end
        entry = { model: model.strip }
        entry[:thinking] = thinking unless thinking.nil?
        parsed[name] = entry
      end
      { version: 1, roles: parsed, unknown_roles: unknown_roles }
    end

    # Layered resolution: the global architect.yaml is the base layer, the
    # space-local file overrides it per role key. Returns nil when neither
    # exists — the quiet no-op case. A found but malformed file throws.
    def resolve_config(start_dir, global_file: nil, env: ENV)
      global = global_file || global_config_file(env)
      space_root = find_space_root(start_dir)
      space_file = space_root ? File.join(space_root, "architect.yaml") : nil
      layers = [global, space_file].compact.select { |file| File.exist?(file) }
      return nil if layers.empty?

      merged = {}
      unknown = []
      layers.each do |file|
        parsed = parse_architect_yaml(File.read(file), file)
        merged.merge!(parsed[:roles])
        unknown.concat(parsed[:unknown_roles])
      end
      unknown = unknown.uniq
      AGENT_ROLES.each_key do |role|
        unless merged[role]
          parse_fail(layers.join(" + "), "roles.#{role}",
            "every loop role (#{AGENT_ROLES.values.join(", ")}) routed to a model")
        end
      end
      { version: 1, roles: merged, space_root:, files: layers, unknown_roles: unknown }
    end

    # pi splitModelSpec (:77-86): a `:level` suffix counts only when it
    # names a THINKING_LEVELS entry, so a model id that merely contains a
    # colon keeps working.
    def split_model_spec(ref)
      ref = ref.to_s
      idx = ref.rindex(":")
      if idx
        level = ref[(idx + 1)..]
        return { model: ref[0...idx], thinking: level } if THINKING_LEVELS.include?(level)
      end
      { model: ref }
    end

    # The launch model ref for a role (pi composeModelSpec :89-93): a
    # `:level` suffix on the model beats the thinking key.
    def compose_model_spec(role_config)
      split = split_model_spec(role_config[:model])
      thinking = split[:thinking] || role_config[:thinking]
      thinking ? "#{split[:model]}:#{thinking}" : split[:model]
    end

    # One catalog entry's field: typed Shapes::Model values answer readers;
    # hand-built raw-hash entries answer [].
    def model_entry_field(entry, field)
      entry.respond_to?(field) ? entry.public_send(field) : entry[field]
    end

    # Loud spawn-contract validation (pi validateModelRef :268-289 on the
    # I78 seat): +catalog+ nil = parse-only; an EMPTY or errored catalog
    # never validates (a corrupt models.json must not break the loop's
    # launches); otherwise the provider/id must resolve exactly.
    def validate_model_ref(role, ref, catalog)
      model = split_model_spec(ref)[:model]
      slash = model.index("/")
      if slash.nil? || slash.zero? || slash == model.length - 1
        raise Error, "architect.yaml: roles.#{role}.model #{ref.inspect} — expected provider/model-id[:thinking]"
      end
      provider = model[0...slash]
      model_id = model[(slash + 1)..]
      return if catalog.nil?
      return if catalog.error || catalog.model_entries.empty?
      return if catalog.resolve("#{provider}/#{model_id}")

      choices = catalog.model_entries.map do |entry|
        "#{model_entry_field(entry, :provider)}/#{model_entry_field(entry, :id)}"
      end.join(", ")
      raise Error,
        "architect.yaml: roles.#{role}.model '#{ref}' does not resolve in this session's model registry " \
        "(provider '#{provider}', id '#{model_id}'). Valid choices: #{choices}"
    end

    # --- role agents: render + write (A-Law 3, .tart/agents ONLY) ---

    # Render one role's complete agent file: YAML frontmatter carrying
    # EXACTLY the fields tart's profile contract consumes, over the role's
    # playbook body. line_width: -1 keeps every scalar on one line — the
    # pi lineWidth: 0 discipline (a folded scalar would arrive truncated at
    # a line-based reader). Psych quotes where YAML demands it, so the file
    # round-trips through YAML.safe_load. The pi-only fields
    # (systemPromptMode, inheritProjectContext) are NOT emitted: replace is
    # tart's only system-prompt mode and the contract tolerates-and-ignores
    # them — tart does not pretend to be pi (ruling 3).
    def render_agent_file(role, config)
      routing = config[:roles][role]
      split = split_model_spec(routing[:model])
      thinking = split[:thinking] || routing[:thinking]
      fields = {
        "name" => AGENT_ROLES[role],
        "description" => ROLE_DESCRIPTIONS[role],
        "tools" => ROLE_TOOLS[role].join(", "),
        "model" => split[:model]
      }
      fields["thinking"] = thinking if thinking
      fields["context"] = "fresh"
      frontmatter = YAML.dump(fields, line_width: -1) # "---\nname: ...\ncontext: fresh\n"
      "#{frontmatter}---\n#{ROLE_PLAYBOOKS[role]}"
    end

    # Write every role's agent file to <space_root>/.tart/agents/,
    # write-if-changed, self-cleaning retired ones (pi writeAgentFiles
    # :378-399). Write failures raise — a half-generated space is loud.
    def write_agent_files(space_root, config)
      agents_dir = File.join(space_root, ".tart", "agents")
      FileUtils.mkdir_p(agents_dir)
      result = { written: [], unchanged: [], removed: [] }
      AGENT_ROLES.each_key do |role|
        file = File.join(agents_dir, "#{AGENT_ROLES[role]}.md")
        content = render_agent_file(role, config)
        if File.exist?(file) && File.read(file) == content
          result[:unchanged] << file
          next
        end
        File.write(file, content)
        result[:written] << file
      end
      RETIRED_AGENT_FILES.each do |name|
        file = File.join(agents_dir, name)
        next unless File.exist?(file)

        File.delete(file)
        result[:removed] << file
      end
      result
    end

    # The --from plan file named in /loop args, or nil for an inline plan
    # (pi fromFileArg :400-403).
    def from_file_arg(args)
      trimmed = args.to_s.strip
      return nil unless trimmed.match?(/\A--from(?:\s|\z)/)

      trimmed["--from".length..].to_s.strip
    end

    # /loop arg parsing (pi extractPlan :405-419): the plan is the args
    # text, or the file named after --from.
    def extract_plan(args)
      trimmed = args.to_s.strip
      file = from_file_arg(args)
      if file
        raise Error, "/loop --from needs a file path: /loop --from <plan file>" if file.empty?

        begin
          text = File.read(file)
        rescue StandardError => e
          raise Error, "/loop --from #{file}: cannot read plan file (#{e.message})"
        end
        plan = text.strip
        raise Error, "/loop --from #{file} is empty — expected the plan text" if plan.empty?

        return plan
      end
      raise Error, "Usage: /loop <plan text> — or /loop --from <plan file>" if trimmed.empty?

      trimmed
    end

    # pi noConfigMessage + INIT_HINT, carried verbatim (they name the
    # architect CLI — harness-agnostic).
    def no_config_message(start_dir, env: ENV)
      "no architect.yaml found — looked for architect.yaml next to space.yaml upward from #{start_dir}, " \
        "and #{global_config_file(env)}. #{INIT_HINT}"
    end

    # Shared generation pass behind session_start, /loop, and the
    # architect_loop tool (pi generateAgentFiles :453-478): the ONE
    # unknown-roles deprecation inform per surface invocation, loud model
    # validation (a bad pin rejects BEFORE any file write), then the
    # space-scoped regeneration. Generation is space-scoped by design: a
    # global-only config has no space root to land files in, so there is
    # nothing to generate. The pi trust-footgun inform is SKIPPED — the pi
    # trust mechanic has no tart analog (.tart/ resources are not
    # trust-requiring). +catalog+ is the LOADER callable (fresh per pass —
    # the I78 per-spawn-fresh precedent; A-Law 9).
    def generate_agent_files(config, output:, catalog:, env: ENV)
      unless config[:unknown_roles].empty?
        output.call(
          "architect-loop: unknown role key(s) in architect.yaml — ignored: #{config[:unknown_roles].join(", ")}. " \
          "Known roles: #{ROLE_NAMES.join(", ")}."
        )
      end
      config[:roles].each do |role, routing|
        validate_model_ref(role, routing[:model], catalog.call)
      end
      return unless config[:space_root]

      write_agent_files(config[:space_root], config)
      nil
    end

    # --- driver mode: the launch path behind /loop and the tool ---

    # The driver playbook (A-Law 6): the operating instructions for the
    # session that launches the loop, in place of the retired detached
    # architect-coordinator. ONE composer, two consumers — the
    # architect_loop result text and architect_compact's customInstructions
    # while driver mode lasts — so they cannot drift. +plan_ref+ is the
    # --from path when launched from a file; for an inline launch it is the
    # literal marker `inline plan text` and the plan text (+plan+) is
    # embedded verbatim — the playbook is then the plan's only home on this
    # machine, so it rides in every compaction. Harness-agnostic sentences
    # are pi's verbatim; mechanism sentences are re-expressed in tart terms
    # (the subagent tool's spawn/reply spelling, the tart cwd law, the
    # no-abort port note) — every divergence is itemized in the lane
    # report's deviation table.
    def driver_playbook(config, plan_ref, plan = nil)
      # The standing routing pins, composed provider/id[:thinking] per role —
      # spelled out so the driver never falls back to a default model mid-plan.
      pins = AGENT_ROLES.keys.map do |role|
        "architect-#{role} #{compose_model_spec(config[:roles][role])}"
      end.join(", ")
      plan_line = if plan_ref == INLINE_PLAN_REF
        "#{INLINE_PLAN_REF} — it lives nowhere on disk, so it is embedded verbatim below and rides in this " \
          "playbook (the compaction keep-essentials)."
      else
        "#{plan_ref} — read it from disk at every wake, never from a remembered copy"
      end
      <<~PLAYBOOK
        You are the architect session driving one space-architect plan to completion by spawning role subagents and tending them. You never do lane work yourself.

        You are installed mid-turn: begin driving NOW, in this same turn — ground from disk and proceed to the first child spawn. Never end your turn before the first child of this session is in flight; an idle driver with no child in flight has no wake source, and the loop stalls.

        Ground from disk at every wake — space.yaml, the plan under notes/plan-, and `architect looplog` — never conversation memory. If this session crashed or was resumed, re-derive where the plan stands from those records and continue.

        The plan: #{plan_line}#{plan ? "\n\n#{plan}" : ""}

        Work the plan's iterations in order, skipping iterations already finished (check the space's build/ reports and architecture/ verdicts first). For each iteration:

        1. Spawn architect-spec via the subagent tool (agent "architect-spec", async, task = the iteration's plan entry, verbatim). Once the spawn is confirmed running, best-effort ping phase spec-launched: bash `architect ping <iteration-id> spec-launched` from the space root. Tend it to completion.
        2. Run `architect provision` via bash to create the iteration's lanes and worktrees.
        3. The spec report names each lane's scratch prompt path. Copy each to build/<iteration-id>-<lane>/prompt.md (bash cp is fine).
        4. Spawn one architect-builder per lane via the subagent tool (agent "architect-builder", async): task = point the builder at build/<iteration-id>-<lane>/prompt.md, tell it to read that file before anything else, and name that lane's worktree as its working directory. Tend each to completion; once every builder is done, best-effort ping phase builders-settled: bash `architect ping <iteration-id> builders-settled` from the space root.
        5. Spawn architect-judge via the subagent tool (agent "architect-judge", async, task = judge this iteration by id). Once it is confirmed running, best-effort ping phase judge-running: bash `architect ping <iteration-id> judge-running` from the space root. Tend it.

        Phase pings are best-effort: a ping that fails (unconfigured, dead server, bad exit) is one line in the completion report — never an exception, never a gate, never retried in a loop.

        Spawn contract: every role spawn is a subagent tool call carrying async: true and an explicit timeout_ms sized for that role's whole run — spec 3600000, builder 7200000, judge 7200000, narrator 300000 — never the 30-minute default. Every spawn also carries an explicit model pin from the standing routing: #{pins}. If the plan pins model/thinking for a role on a specific iteration, pass that pin in the spawn's model field as provider/id[:thinking] — it overrides the standing routing for that spawn. (tart cwd law: role children always run in THIS session's cwd — launch the driver from the space root so spec/judge/narrator children land there; a builder child honors its lane-worktree cwd law through its task, which names the worktree as the working directory to work inside.)

        Compaction: call the architect_compact tool after every child launch, while a child is in flight — the tool self-guards on context size, so a call under the compaction threshold is a cheap no-op: keep the cadence, never measure tokens yourself. When it does compact, this playbook (with the plan reference and routing pins) is the compaction's keep-essentials, and it is re-sent into the session after every compaction; everything else is recoverable from disk. A child in flight is the wake source that resumes the session after the compaction aborts the turn: NEVER compact before this session's first child launch, and never once every child has settled — that leaves an aborted turn with no wake source, and the loop stalls. (Port note: the tart port never aborts the turn — architect_compact schedules the compaction at the post-run point; the tool result returns, the run ends, the compaction lands, and the in-flight child's completion wake resumes the session; every compaction — the scheduled ones and the loop's own alike — also re-sends this playbook as a next-turn message the next wake delivers.)

        Tending: rely on native async completion wakes. Never sleep and never poll-loop. If a child died as infrastructure (failed to start, or crashed before doing any work), relaunch it ONCE. A child that hit its timeout is not infrastructure death, and reviving its session fails deterministically upstream — do not attempt resume: launch exactly one replacement in the same cwd with a larger explicit timeout_ms, and make auditing the inherited uncommitted diff its first task. Anything else — a failed child, a verdict you cannot act on, anything you cannot root-cause — is an exception.

        Narration: narrate RARELY — the phase pings above already carry the launch and settle churn, and the human reading notes/narrative-<UTC timestamp>-<kind>.md has stale context, so each spawn is a best-effort prose refresh for them, never a gate on the loop. One architect-narrator spawn per iteration at verdict-landed, plus exception and plan-complete; its task carries the kind, the iteration id, the UTC timestamp for the filename, and the paths worth reading. The kinds and their settle points: verdict-landed (ONE per iteration — the judge finished; the verdict, the per-AC rollup, and the integration result in hand), exception (after notes/exception-<UTC timestamp>.md is written, before you terminate), plan-complete (the last planned iteration finished — no successor). Back-to-back rule: when two narration-worthy events are back-to-back, exactly ONE narration lands — the more-final kind absorbs the earlier event's facts (plan-complete absorbs the final iteration's verdict-landed; exception absorbs a verdict that immediately precedes it). The narrator spawn contract is unchanged: timeout_ms 300000, the standing model pin, best-effort — a narrator that dies or times out is one line in the completion report or the next narration's facts — never an exception, never a relaunch, never a gate on the loop.

        Escalation, one hop: when a child raises a need_decision, it lands in THIS session — you are the judgment seat. Relay it mechanically: forward the child's question verbatim to the human, prefixed with one line of triage (iteration, lane, what is blocked). Never re-author, compress, or provisionally answer it; a re-authored escalation suppresses the human's independent read. When the ruling arrives, deliver it to the child unchanged via the subagent tool's reply action on the PENDING REQUEST'S id: subagent({ action: "reply", reply_to: "<requestId>", message: "..." }). When no ruling can be had, write the verbatim question plus your triage line to notes/escalation-<UTC timestamp>.md and stop via the exception path.

        Exception: write notes/exception-<UTC timestamp>.md with the raw facts (what happened, which iteration, child run ids, last command outputs), then narrate exception and tend that narrator to completion — the one narration you wait on; if a verdict landed immediately before, the exception narration absorbs it (one narration, not two) — then terminate. Do not improvise repairs.

        On a judge verdict of CONTINUE, narrate verdict-landed once the integration result is in hand, then work the next planned unfinished iteration. On KILL, narrate verdict-landed once the integration result is in hand, then stop.

        You never edit files except your own notes/ reports (a bash redirect is fine for those), and you never write anything into architecture/. On normal completion of the last planned iteration, write notes/report-<UTC timestamp>.md summarizing iterations, verdicts, and child run ids, then narrate plan-complete — no successor follows it, and it absorbs the final iteration's verdict-landed (one narration, not two). Decision-bearing documents (escalations, exception and completion reports) and narrations live in notes/, committed with the space — build/ stays ephemeral per-run scratch.
      PLAYBOOK
    end

    # Shared driver-mode install behind both surfaces (pi installDriverMode
    # :541-552): compose the playbook, mark the session as driver and
    # return the playbook. No compaction is scheduled here: the driver
    # begins working in this same turn and first compacts (via
    # architect_compact) after its first child launch. Returns the playbook
    # (the tool surface returns it verbatim as its result text).
    def install_driver_mode(config, plan_ref, plan, output:)
      playbook = driver_playbook(config, plan_ref, plan)
      @driver_playbook_text = playbook
      output.call(
        "architect loop: driver mode engaged — this session now drives the plan (#{plan_ref}); " \
        "driving starts this turn, first architect_compact after the first child launch."
      )
      playbook
    end

    # True when cwd is a lane worktree: <space>/build/<id>-<lane>/wt (pi
    # isLaneWorktree :554-558).
    def is_lane_worktree?(cwd)
      return false if cwd.nil? || cwd.empty? || File.basename(cwd) != "wt"

      File.basename(File.dirname(File.dirname(cwd))) == "build"
    end

    # --- builder-guard.ts, ported (the git-write deny law; the bash -n
    # parse denial is a pi-harness turn-economy guard with no tart analog —
    # declared exclusion, itemized in the lane report) ---

    # Split a command line into simple-command segments at the shell's
    # command separators. Whitespace tokenization only: this is a deny
    # list, not a shell reimplementation, and the deny decision never
    # depends on quoting structure beyond what the separator split already
    # crossed.
    def command_segments(command)
      command.split(/\r?\n|\|\||&&|[;|]/)
    end

    # The git subcommand a segment invokes, or nil: walk the tokens after
    # `git`, skipping global flags (and their values) so the first
    # positional token is the subcommand. Never substring-match the raw
    # command — `git log --grep=commit` mentions `commit` but is a read.
    def git_subcommand(segment)
      tokens = segment.strip.split(/\s+/)
      return nil unless tokens.first == "git"

      # Index walk (pi's for with the in-body i++ — the `-C`/`-c` VALUE is
      # skipped): the first non-flag token after git is the subcommand.
      i = 1
      while i < tokens.length
        tok = tokens[i]
        return tok unless tok.start_with?("-")

        i += 1 if GIT_VALUE_FLAGS.include?(tok) # skip the flag's value
        i += 1
      end
      nil
    end

    # The git-write denial for a bash command: why it must not run, or nil
    # (pi gitWriteDenial — the denial sentence carried verbatim).
    def guard_denial(command)
      command_segments(command).each do |segment|
        sub = git_subcommand(segment)
        if sub && GIT_WRITE_VERBS.include?(sub)
          return "git #{sub} writes repository state — the architect CLI owns all commits and git mutations; " \
            "leave repository state alone and report what you would have run"
        end
      end
      nil
    end

    # --- driver compaction threshold (pi architect-loop.ts :453-475, the
    # 6576da6 update): the cadence compacts only a meaningfully full
    # context ---

    # The floor: never compact on cadence below this many tokens, whatever
    # the window (pi COMPACT_FLOOR_TOKENS).
    COMPACT_FLOOR_TOKENS = 150_000
    # The window fraction: ~15% of the context window (pi
    # COMPACT_WINDOW_FRACTION; 150k on a 1.0M window).
    COMPACT_WINDOW_FRACTION = 0.15

    # The driver-cadence compaction threshold (pi compactionThreshold): the
    # harder-to-reach of the token floor and the window fraction — a small
    # window never slides back into over-compaction (the failure this
    # threshold exists to fix), a large window scales up.
    def compaction_threshold(context_window)
      [COMPACT_FLOOR_TOKENS, (COMPACT_WINDOW_FRACTION * context_window).floor].max
    end

    # True only strictly over the threshold (pi shouldCompact); nil tokens
    # (just compacted, no estimate yet) never compact.
    def should_compact?(tokens, context_window)
      !tokens.nil? && tokens > compaction_threshold(context_window)
    end

    # --- surfaces (A-Law 4/5: two surfaces, one code path) ---

    # The /loop command handler (pi registerCommand loop :599-609): parse
    # the args, resolve config, pre-flight regenerate, install. The handler
    # RESCUES its own errors and prints them via the output callable —
    # loud, never a silent no-op, never a crash of the submit path.
    def run_loop_command(args, cwd:, env: ENV, output:, catalog:)
      plan = extract_plan(args)
      config = resolve_config(cwd, env: env)
      raise Error, no_config_message(cwd, env: env) unless config

      generate_agent_files(config, output:, catalog:, env: env)
      plan_file = from_file_arg(args)
      install_driver_mode(config, plan_file || INLINE_PLAN_REF, plan_file ? nil : plan, output:)
    rescue StandardError => e
      output.call(e.message)
      nil
    end

    # Wires the module onto the seam (A-Law 1, called ONCE from the
    # interactive boot beside the Memory/Herdr registers, BEFORE
    # build_tools): the two tools, the /loop command, the session_start
    # handler, and the tool_call builder guard. +catalog+ is the validation
    # catalog LOADER (fresh per pass — the A-Law 9 law; the default is
    # Models.load over the default agent root, exactly the boot's own
    # catalog seam; tests stage a loader over a staged root).
    def register(hooks:, cwd:, identity: Identity::DEFAULT, agent:, output:, env: ENV, catalog: nil)
      catalog_loader = catalog || -> { Models.load }
      hooks.register_tool(Tools::ArchitectLoop.new(cwd:, output:, env:, catalog: catalog_loader))
      hooks.register_tool(Tools::ArchitectCompact.new(driver: self, agent:))

      hooks.register_command("loop", description: LOOP_COMMAND_DESCRIPTION, args: true) do |args|
        run_loop_command(args, cwd:, env: env, output:, catalog: catalog_loader)
      end

      # session_start (pi :573-582): capture-free — the context's cwd is
      # the session cwd (the memory-module idiom); a fresh, resumed, or
      # /new'd session is not driving until a launch installs the playbook
      # (driver mode is never inherited); a config regenerates the role
      # files + validates (mid-session architect.yaml edits land before the
      # spawns); no config anywhere = quiet no-op. A malformed config
      # raises LOUD through the hooks channel's once-per-handler warn.
      hooks.on("session_start") do |_event, context|
        session_cwd = context.is_a?(Hash) ? (context[:cwd] || cwd) : cwd
        @driver_playbook_text = nil
        config = resolve_config(session_cwd, env: env)
        generate_agent_files(config, output:, catalog: catalog_loader, env: env) if config
      end

      # Every compaction — the architect_compact cadence's own and the
      # loop's auto-compaction alike — emits :compaction. While driving,
      # the playbook is re-sent right after it (pi's session_compact hook,
      # architect-loop.ts :635-644): the loop's own compactions carry no
      # customInstructions, so without the re-send an auto-compaction would
      # strip the driver's operating instructions mid-drive. The I47
      # send_next_turn queue is pi's sendMessage({triggerTurn: false})
      # analog — queue only; the next wake (the in-flight child's
      # completion) drains it, so a re-send never opens a turn by itself.
      hooks.on(:compaction) do |_event, _context|
        next if @driver_playbook_text.nil?

        hooks.send_next_turn(custom_type: "architect-driver-playbook",
                             content: @driver_playbook_text, display: false)
      end

      # The builder guard for subagent-spawned builders (pi :583-591):
      # `architect dispatch` injects its own vendored guard, but subagent
      # spawns have no injection path — the module denies git writes in any
      # session whose cwd is a lane worktree. Dispatch-run builders get
      # both guards; they deny identically, so the double up is harmless.
      # Non-matching events return nil (no block — zero behavior change).
      hooks.on_tool_call do |event, _context|
        next unless event["tool_name"] == "bash" && is_lane_worktree?(cwd)

        command = event.is_a?(Hash) && event["input"].is_a?(Hash) ? event["input"]["command"] : nil
        next unless command.is_a?(String)

        denial = guard_denial(command)
        next unless denial

        { block: true, reason: "architect builder guard: #{denial}" }
      end
      self
    end
  end
end
