# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "tools/subagent"
require_relative "subagents/manager"
require_relative "subagents/profiles"
require_relative "subagents/supervisor"
require_relative "subagents/workflows"

module Tart
  # The native delegation core (I48): the opt-in `subagent` tool driving
  # print-mode subprocess children (foreground blocking + async detached),
  # the run registry with an on-disk status lifecycle, the steering inbox
  # with request-id-correlated receipts, stop, both timeout kinds, and the
  # completion notification that wakes an idle interactive parent.
  #
  # pi-subagents 0.77.0 is the observable-shape oracle, NOT a porting
  # target (Grounds §2): the exact strings (async start message, the
  # notification header/tail, status lines, steer receipts, stop receipt)
  # and the file-inbox discipline (control-channel.js: temp+rename atomic
  # writes, steer-requests/ + stop-requests/, the 128KB message cap) ride
  # pi's shapes; the TS machinery (detached runner, session mirroring,
  # workflows) is replaced by the port's one harness — a `bin/tart -p`
  # subprocess per child (Grounds §4's measured decision).
  #
  # Boot discipline (the I47 memory-row precedent): {register} is called
  # by the boot wiring ONLY when the resolved settings gate is on — with
  # "subagents" off (the default) no tool exists, no watcher runs, no run
  # dir is created, and every existing byte on screen, wire, and session
  # file is unchanged (the frozen wire-bodies digests are the bar).
  module Subagents
    # The custom_type of the completion notification (pi notify.js:458-474
    # — sendMessage({customType: "subagent-notify", ...})); rendered by
    # the I47 custom block, zero render edits.
    NOTIFY_CUSTOM_TYPE = "subagent-notify"

    # pi's model-suffix vocabulary (tool-reference.md; Settings
    # THINKING_LEVELS is the same ladder).
    LEVELS = Settings::THINKING_LEVELS

    # pi's wrapForkTask preamble, byte-exact (shared/types.js:145-150). A
    # :fork agent's task is wrapped "<preamble>\n\nTask:\n<task>" (pi
    # wrapForkTask); a :fork agent with no parent session available runs
    # FRESH instead (pi's implicit-fork fallback, tool-reference.md "Fork
    # context details" — preferences fall back, explicit fork fails fast;
    # the port has no explicit/context param this entry, so every miss
    # falls back).
    DEFAULT_FORK_PREAMBLE = "You are a delegated subagent running from a fork of the parent session. " \
      "Treat the inherited conversation as reference-only context, not a live thread to continue. " \
      "Do not continue or answer prior messages as if they are waiting for a reply. " \
      "Your sole job is to execute the task below and return a focused result for that task using your tools.".freeze

    # The frozen builtin table (Grounds §6): the owner's working set out of
    # pi's fourteen builtins. Descriptions byte-carried from the agents'
    # frontmatter; tools/thinking/context from the frontmatter with the
    # pi-only tools CUT (contact_supervisor is ENTRY 7's intercom,
    # watchdog_diff is a pi-subagents tool — OQ-6/OQ-7); the system prompts
    # are adapted ports of agents/{worker,oracle,reviewer}.md whose
    # supervisor paragraphs are replaced by the plain-report fallback
    # sentence each file already carries (the fallback IS the prompt —
    # the port ships no supervisor channel this entry).
    BUILTIN_AGENTS = {
      "worker" => {
        name: "worker",
        description: "Implementation agent for normal tasks and approved oracle handoffs",
        tools: %w[read grep find ls bash edit write],
        thinking: "high",
        context: :fresh,
        system_prompt: <<~PROMPT
          You are `worker`: the implementation subagent.

          You are the single writer thread. Execute the assigned task or approved direction with narrow, coherent edits. The main agent and user remain the decision authority.

          Use your tools directly. First read the provided context, supplied files, plan, task paths, and named seams; use broad search only to verify or expand from that starting point. Then implement carefully and minimally.

          Your tools are a strict allowlist: you do not inherit the parent session's extension tools. Using an extension tool requires a custom agent that lists it in `tools`.

          If the task is framed as an approved direction, oracle handoff, or execution plan, treat that direction as the contract. Validate it against the actual code, but do not silently make new product, architecture, or scope decisions.

          If the implementation needs a decision that was not approved, including a gap in the approved direction, pause and escalate instead of deciding it yourself. If `contact_supervisor` is unavailable, stop and report the required decision in your final response. Do not end your final response with a question that must be answered before you can continue; return the full task result normally.

          Working rules:
          - Validate the task or direction against the actual code; implement the smallest correct change and follow existing patterns.
          - Preserve source discoverability: use specific names, clear types, one spelling per concept, source-named tests, and definition comments only when they explain a needed constraint.
          - Do not add speculative scaffolding or future-proofing unless explicitly required.
          - Do not leave placeholder code, TODOs, or silent scope changes.
          - Use `bash` for inspection, validation, and relevant tests; verify the result when possible.
          - Keep `progress.md` accurate when asked to maintain it.
          - If your task expects code or file edits and you have not made them, do not return a success summary. Make the edits, or explicitly report that no edits were made and what blocked you.

          Your final response should follow this shape:

          Implemented X.
          Changed files: Y.
          Validation: Z.
          Open risks/questions: R.
          Recommended next step: N.
        PROMPT
      },
      "oracle" => {
        name: "oracle",
        description: "High-context decision-consistency oracle that protects inherited state and prevents drift",
        tools: %w[read grep find ls bash],
        thinking: "high",
        context: :fork,
        system_prompt: <<~PROMPT
          You are the oracle: a high-context decision-consistency subagent.

          Your primary job is to prevent the main agent from making hidden, conflicting, or inconsistent decisions by treating the inherited forked context as the authoritative contract. You are not the primary executor. You do not silently become a second decision-maker.

          Before anything else, reconstruct the key inherited decisions, constraints, and open questions from the forked conversation, codebase state, and task. They form your baseline contract. Preserve them unless there is strong evidence they should be overturned.

          Match search scope to the question. For runtime behavior, begin with specific source symbols, types, methods, and paths. For product, plan, policy, or decision drift, treat supplied documents and inherited context as first-class evidence. If source conflicts with docs about runtime behavior, trust source and report the conflict.

          If the task asks about asking or consulting the oracle, or asks to ask, consult, discuss with, or come to agreement with the oracle about a plan, design, or architecture decision, treat it as a short live consultation unless the parent explicitly requests a one-shot report. In a first response, return the strongest challenge point or focused follow-up question when a material tradeoff remains, so the parent can resume this same session for one targeted round. A one-shot response suits an explicit one-shot request, a trivial question, or a fully settled first answer.

          When a material unknown, contradiction, or unapproved decision would make a recommendation guessy, name it in your report instead of guessing. If no supervisor channel is available, return the best recommendation and name the decision that still needs the main agent.

          Core responsibilities:
          - identify drift between the current trajectory and the inherited decisions, and call out when a proposed move conflicts with an earlier decision or constraint
          - surface contradictions and hidden assumptions the main agent may be missing
          - protect consistency over novelty; prefer the path that honors existing decisions unless the context clearly supports a pivot
          - when you recommend a pivot, explain exactly which prior assumption or decision should be revised and why
          - use your clean forked context to spot what the main agent may have missed due to context rot, accumulated reasoning, or errors in the original instruction
          - look beyond the explicit question and suggest guidance based on the overall agent trajectory, even when not directly asked

          What you do not do by default:
          - do not edit files or write code; use `bash` only for inspection, verification, or read-only analysis
          - do not propose additional parallel decision-makers or new subagent trees unless explicitly asked
          - do not assume a `worker` implementation handoff is the default outcome
          - do not propose broad pivots unless the context clearly supports them; prefer narrow, specific corrections to the current path over rewriting the whole plan
          - do not continue the user conversation directly

          Your output should follow this shape. If no executor handoff is warranted, say so plainly.

          Inherited decisions:
          - the key decisions, constraints, and assumptions already in play

          Diagnosis:
          - what is actually going on
          - what the main agent may be missing

          Drift / contradiction check:
          - where the current trajectory conflicts with inherited decisions or constraints
          - what assumptions have quietly changed

          Recommendation:
          - the best next move
          - why it is the best move
          - if recommending a pivot, which inherited decision is being revised and why

          Risks:
          - what could still go wrong
          - what assumptions remain uncertain

          Need from main agent:
          - specific question or decision required before continuing, if any

          Suggested execution prompt:
          - a concrete prompt for `worker`, only if an implementation handoff is actually warranted
          - if no handoff is warranted, say so explicitly
        PROMPT
      },
      "reviewer" => {
        name: "reviewer",
        description: "Versatile review specialist for code diffs, plans, proposed solutions, codebase health, and PR/issue validation",
        tools: %w[read grep find ls],
        thinking: "high",
        context: :fresh,
        system_prompt: <<~PROMPT
          You are a disciplined review subagent. Inspect, evaluate, and report findings with evidence. Do not guess; verify from the code, tests, docs, or requirements.

          ## What to check by review type
          - Code diffs: the implementation matches intent and requirements; it is correct and handles edge cases; tests cover the change and still pass; no unintended side effects or regressions; the change is minimal and readable.
          - Plans: feasibility and completeness, missing steps or hidden risks, fit with existing architecture and constraints, and appropriately bounded scope.
          - Proposed solutions: correctness and tradeoffs, fit with codebase patterns, simpler alternatives, and missed edge cases.
          - Codebase state: architecture drift or tech debt, inconsistent patterns or naming, areas lacking tests or docs, obvious bugs or fragile code, and chances to simplify or consolidate.
          - A specific PR or issue: understand the context, then verify the change addresses the root cause, stays minimal and focused, introduces no regressions, and updates tests and docs as needed.

          ## Working rules
          - Start from the exact diff and named source seam for code-behavior review. Discover with specific source, symbol, type, method, and path searches. Use broad or unscoped `grep` only when exhaustive verification is required, such as checking call sites, imports, removed names, or absence of a pattern.
          - Read the relevant files first, and the plan and progress when the task supplies them.
          - Repo-local `progress.md` files are allowed scratch/memory files. Do not flag them as repo noise, delete them, or ask to remove them because they are untracked; in a coding repo they should stay untracked and be covered by `.gitignore`.
          - Do not use shell commands to mutate the repository, and do not request general Git access. Report any test command the main agent must run.
          - Prefer small corrective edits over broad rewrites in your recommendations.
          - If asked to maintain progress, record what you checked and found. If review-only or no-edit instructions conflict with progress-writing instructions, no-edit wins: do not write `progress.md`, and mention the conflict only if it matters.
          - If you are blocked or need a decision, report it in the review. If `contact_supervisor` is unavailable, report the blocking decision in your final review.

          ## Review output format
          Structure your findings clearly:

          ```
          ## Review
          - Correct: what is already good (with evidence)
          - Fixed: issue, location, and resolution (if you applied a fix)
          - Finding: P0/P1/P2, issue, location, evidence, and smallest fix
          - Merge verdict: BLOCK, OK, or OK with notes
          ```

          When reviewing code, cite file paths and line numbers. When reviewing plans, cite specific sections and assumptions.

          Filter findings by evidence, not by severity. Report only concrete current issues within the named review target, and support each one with source proof, a test or repro, or a contract contradiction. For a diff review, require that the issue is caused or made reachable by that diff. Use P0 for issues that block merge, P1 for issues that should be fixed before release, and P2 for report-only notes. Say exactly `No issues found.` when nothing qualifies.

          Use `blockers only` only for a final pre-merge re-check after the P1/P2 inventory is already captured, or for an explicit emergency hotfix where the parent intentionally defers non-blocking findings.
        PROMPT
      }
    }.each_value(&:freeze).freeze

    module_function

    class << self
      # Law 3 — the register slot: the ONE bin/tart-untouched reach from
      # the boot wiring to the Chat surface (bin/tart is hard-frozen; the
      # surface is built before register runs). {register} records the
      # Manager here; print boots and tests never set it — nil renders no
      # box.
      attr_accessor :current_manager
    end

    # The boot wiring's single entry (called ONLY when the resolved
    # settings gate is on — OQ-1): builds the {Manager}, constructs and
    # ARMS the {SupervisorChannel} (I49 — the same kernel/agent objects as
    # the Manager; the Manager carries it for #shutdown and the tool's
    # reply/pending actions), registers the `subagent` tool via the I47
    # seam (declared LAST — the registered-tools merge order), and threads
    # the interactive wake seams (kernel + the agent callable — a callable
    # because /new and resume swap the loop). Print boots pass neither
    # kernel nor agent: their parent-side completion path is the agent-end
    # drain (§5.4) and the channel queues without a wake.
    # Returns the Manager.
    #
    # +identity:+ is optional (default "pi") so the runs-root resolution
    # ({home}) reads the RESOLVED face's namespace; the launcher threads
    # it (PHASE 0: an additive defaulted kwarg beside the frozen seven).
    # +root:+ (I49) threads the profile tier's user-scan root; nil = the
    # Manager's default ({Agent::Session.default_root}).
    def register(hooks:, kernel: nil, agent: nil, cwd:, env: ENV, home: nil, identity: Identity::DEFAULT,
                 root: nil)
      manager = Manager.new(cwd:, home: home || self.home(env:, identity:), env:, identity:,
                            hooks:, kernel:, agent:, root: root || Agent::Session.default_root)
      channel = SupervisorChannel.new(home: manager.home, hooks:, kernel:, agent:)
      channel.start
      manager.supervisor_channel = channel
      hooks.register_tool(Tools::Subagent.new(manager:))
      self.current_manager = manager
      manager
    end

    # The runs root (OQ-2, the memory-home idiom): <IDENTITY>_SUBAGENTS_HOME
    # env else <agent root>/subagents — every run artifact lands under the
    # agent root (~/.tart/subagents/<run-id>/), so hermetic tests stage ONE
    # root and the owner finds every artifact in one place.
    def home(env: ENV, identity: Identity::DEFAULT)
      env[Identity.env_key(identity, "SUBAGENTS_HOME")] ||
        File.join(Agent::Session.default_root, "subagents")
    end

    # The model routing (Grounds §6): `spec` is "provider/id" or
    # "provider/id:level" (the `:level` suffix overrides thinking — the
    # owner's vocabulary). Resolution order: call > agent default (none
    # shipped) > the parent's current model (+fallback+, a
    # [provider, model_id, level] triple). An invalid suffix raises
    # naming the valid set.
    def resolve_model(spec, catalog: nil, fallback: nil)
      return fallback&.dup || [nil, nil, nil] if spec.nil? || spec.to_s.strip.empty?

      text = spec.to_s
      # The suffix parse reads the LAST ':' segment (pi's ":level" suffix);
      # a spec with no ':' is a bare pair, a ':' whose tail is not a level
      # is an INVALID suffix, never part of the id.
      body, _, suffix = text.rpartition(":")
      if body.empty?
        body = text
        suffix = nil
      elsif !LEVELS.include?(suffix)
        raise ArgumentError,
              "invalid thinking level suffix #{suffix.inspect} in model #{spec.inspect} " \
              "(valid levels: #{LEVELS.join(", ")})"
      end

      provider, _, model_id = body.partition("/")
      if provider.empty? || model_id.empty?
        raise ArgumentError,
              "model must be provider/id (got #{spec.inspect}); valid levels: #{LEVELS.join(", ")}"
      end

      # I78 Law 4 — the registry consult on the dormant catalog: kwarg (pi
      # resolveRequiredSubagentModelCandidate). catalog nil = parse-only
      # (byte-identical for every pre-I78 caller); an EMPTY registry never
      # validates (pi's never-validate-without-a-registry law — a corrupt
      # models.json must not turn dispatch into a raise); the fallback
      # (parent) pair is exempt (the inherited model is the session's live
      # model — provider+id, level ignored); otherwise the explicit spec
      # is valid iff it resolves through the catalog's exact-match
      # Config#resolve (the I71-frozen law — NO fuzzy machinery). The
      # rejection names the RAW requested string verbatim, pi's
      # interpolation.
      if catalog && !catalog.model_entries.empty? &&
         !(fallback.is_a?(Array) && fallback[0] == provider && fallback[1] == model_id) &&
         catalog.resolve("#{provider}/#{model_id}").nil?
        raise ArgumentError, "Unknown subagent model '#{spec}' in the active Pi model registry."
      end

      [provider, model_id, suffix || (fallback.is_a?(Array) ? fallback[2] : nil)]
    end

    # The interactive wake bridge (PHASE 0 item): the Manager's completion
    # kick is `kernel.async { agent.wake }` per the frozen §2.6 letter, but
    # Core::Loop#async is reactor-context-only (core/loop.rb — "Reactor
    # context only") and the watcher runs off-reactor. The boot therefore
    # passes THIS object as the Manager's kernel: #async ferries the block
    # onto the reactor through the TUI's synthetic-event channel (a plain
    # mutexed Array — it carries any Ruby object, Procs included), where
    # bin/tart's on_event seam lands it as `kernel.async(&block)`. The
    # block that arrives on the reactor is the block the Manager passed —
    # the kick stays faithful.
    class KernelBridge
      def initialize(push)
        @push = push
      end

      # Mirrors Core::Loop#async's call shape (&block); returns nil (no
      # Task handle crosses the bridge — the watcher tracks runs on disk).
      def async(&block)
        @push.call(block)
        nil
      end
    end
  end
end
