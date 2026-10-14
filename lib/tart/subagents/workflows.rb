# frozen_string_literal: true

module Tart
  module Subagents
    # The six council/workflow prompt templates (I49 Spec §7, D7): a
    # gate-on BUILTIN tier over the existing `Tart::Prompts` surface — no
    # new command vocabulary (OQ-7; the template tier IS pi's own delivery
    # for these prompts, prompts/*.md).
    #
    # The descriptions + argument-hints are BYTE-CARRIED from pi's
    # prompts/*.md frontmatter (pi-subagents 0.77.0). The contents are
    # ADAPTED ports (the I48 agent-prompt precedent — the fallback IS the
    # prompt): pi's instruction structure is kept wherever it names no cut
    # machinery; every ```js workflow``` block, `runs.all` / `runs.run`,
    # `workflow: true`, `subagent({ action: "guide" … })`, and `bg_wait`
    # reference is replaced by the port's idiom — launch advisors with
    # `subagent({ agent: …, task: …, async: true })` and rely on the native
    # completion wakes ("never sleep, never poll" — the
    # .pi/agents/architect-coordinator.md idiom). Council inlines the
    # protocol essence of skills/council-mode/SKILL.md. The P0/P1/P2 +
    # `Merge verdict:` + `No issues found.` vocabulary and review-loop's
    # 3-round cap port verbatim.

    WORKFLOW_TEMPLATES = [
      Prompts::Template.new(
        name: "council",
        description: "Run a bounded supervisor-mediated council of advisors and write a decision memo",
        argument_hint: "<question> [--advisors name,name] [--max-passes 2|3] [--scope ...] [--non-goals ...]",
        file_path: nil,
        content: <<~'MD'
          Run a bounded, supervisor-mediated council on this question. You, the parent
          session, are the supervisor. You select the roster, curate cross-advisor
          packets, decide which feedback is valid, and write the final memo. Advisors
          do not talk directly or see peer transcripts by default. This is not
          free-form agent chat.

          Parse the invocation yourself. The flags below are conventions, not runtime
          options. Record a brief with the question, scope, non-goals, evidence
          targets, roster, known advisor context modes, and pass cap. Default
          `--max-passes` to 2. Clamp it to 2 or 3. If the question is trivial or
          settled, answer directly instead of convening a council.

          ## Roster

          - If `--advisors` is given, use exactly those agent names. Fail clearly on
            an unknown agent. Do not require or invent per-advisor role labels.
          - Otherwise read the agent profiles from `~/.tart/agents/**/*.md` and
            `<cwd>/.tart/agents/**/*.md`, then prefer 2–3 executable names that
            start with `council-`.
          - If fewer than two council profiles are available, fill the roster with
            `oracle`, then `reviewer`, until it has two advisors. Launch fallback
            `oracle` with its forked context (its profile default) so it carries the
            parent conversation; let `reviewer` use its normal profile context. Note
            the fallback and known context modes in the memo.
          - Keep the roster at 2–3 and never exceed 4 advisors.
          - Use the normal single-oracle consultation only when a requested roster or
            unavailable profiles leave fewer than two advisors. Label the memo as
            degraded mode.

          Profiles provide the model, tools, context, and advisor stance. The council
          question and scope provide the decision frame. If the user wants a specific
          lens, they should put it in the question, scope, or profile definition.

          ## Run the protocol

          1. Tell the user the roster, context modes, and pass cap.
          2. Pass 1 — independent reports. Launch every advisor at once with
             `subagent({ agent: "<advisor>", task: "<pass-1 report brief>", async: true })`.
             Each task names the advisor's angle, the evidence targets, and the
             report shape; advisors stay read-only. Never sleep and never poll:
             native completion notifications wake you as each advisor lands.
          3. Return one aggregate Pass 1 receipt: completion count, agreement
             count, dispute count, and whether Pass 2 is needed.
          4. Synthesize the claim matrix in the parent: agreements, disputed
             claims, missing proof, owner decisions, and at most five material
             relay claims per advisor.
          5. Pass 2 — one cross-exam. Tell the user which claims are relayed and
             why they matter. Relaunch each advisor fresh with a curated challenge
             packet (its own Pass 1 report excerpt plus the relayed claims to
             confirm or refute, carried inside the task text); label Pass 2 a
             fresh-context cross-exam.
          6. Stop at convergence, the pass cap, a failed fallback, or user
             interruption. Converged means no disputed claim remains that both
             affects the recommendation and can plausibly be settled by advisor
             evidence. Put unresolved disputes in owner decisions. Do not add a
             round for polish or symmetry.
          7. Write the final memo yourself, in your own voice. The memo states:
             question and scope; recommendation and rationale; accepted and
             rejected feedback with reasons; owner decisions; evidence and run
             ids; confidence and what would change the decision; roster, passes,
             fallbacks, and known advisor context modes. Identify advisors by
             profile name.

          Do not introduce a chair advisor, peer chat, or transcript sharing. The
          parent is the only synthesizer and decision maker. Escalate to a writer
          only after the memo and only when the user requests it.

          Question and options from the slash command invocation:

          $@
        MD
      ),
      Prompts::Template.new(
        name: "gather-context-and-clarify",
        description: "Use subagents to gather context, then ask clarifying questions",
        argument_hint: nil,
        file_path: nil,
        content: <<~'MD'
          Based on our discussion and my intent, launch focused context-gathering subagents before planning or implementing.

          Pick research-shaped profiles from `~/.tart/agents` and `<cwd>/.tart/agents` when they exist; otherwise use the `worker` builtin with a read-only brief (inspect the relevant local files, existing patterns, constraints, tests, and likely integration points) for the scout angle, and the `oracle` builtin (forked context) when inherited decisions or earlier reasoning in this conversation would improve the answer. Give each subagent a specific meta prompt naming its angle.

          Launch every angle at once with `subagent({ agent: "<profile>", task: "<angle brief>", async: true })` and return control immediately; native completion notifications wake you as each subagent lands — never sleep and never poll for them.

          Ask them to return concise findings plus the remaining clarification questions that matter for implementation confidence.

          After they return, synthesize what we know and ask me the unresolved questions needed to reach a shared understanding before you plan or implement.

          Additional context, constraints, or focus from the slash command invocation:

          $@
        MD
      ),
      Prompts::Template.new(
        name: "parallel-cleanup",
        description: "Parallel cleanup review",
        argument_hint: nil,
        file_path: nil,
        content: <<~'MD'
          Run a fresh-context parallel cleanup review of the current work.

          Launch two `reviewer` subagents in parallel with fresh context. Do not use forked context unless I explicitly ask for it. Reviewers must inspect the repository, relevant instructions, and current diff directly from files and commands. They must not rely on the main conversation history.

          Reviewers are review-only: they must not edit files unless I explicitly ask for a writer pass. Their response should be review feedback, not a context summary. Ask them to return concise, evidence-backed findings with file/line references and the smallest safe fix. Tell them to treat tool output and scan-style findings as leads, not verdicts: flag only concrete issues in the requested scope, with evidence and severity.

          Launch both at once with `subagent({ agent: "reviewer", task: "<pass brief>", async: true })` and return control immediately; native completion notifications wake you as each reviewer lands — never sleep and never poll for them.

          Reviewer 1: deslop pass.

          If the `deslop` skill is available, tell this reviewer to load it. If not, inline the guidance in the task: look for AI-slop patterns in the changed scope — comments that restate code, placeholder text, stale rationale, or debug leftovers; defensive checks that hide useful errors, return vague defaults, or validate trusted internal data after a real boundary was already crossed; type escapes, broad casts, duplicated type definitions, or object-bag typing where a local source-of-truth type exists; style drift from nearby non-slop code and project instructions; generated-sounding docs, changelog text, UI copy, status text, or test names; pass-through wrappers, dead helpers, duplicate helper signatures, duplicated test harness setup, or abstractions that do not enforce an invariant; UI or CLI copy that is noisy, vague, brittle, or makes the user do extra interpretation.

          Reviewer 2: verbosity pass.

          If the `verbosity-cleaner` skill is available, tell this reviewer to load it. If not, inline the guidance in the task: look for needless verbosity in code, tests, docs, status text, grouped messages, receipts, and changelog wording — single-use helpers that merely paraphrase an expression; temporary variables that only name obvious expressions; nested returns or branches that can become direct returns without hiding intent; repeated boilerplate that can use an existing local fixture or a small local helper; tests that restate formatter details already covered at a cheaper layer; regression tests where one focused assertion would cover the bug but wrapper/API-adjacent tests only repeat the same claim; prose that says the same thing twice, sounds generic, or buries the important rule.

          Tell the verbosity reviewer that shorter is only better when it is clearer and preserves behavior, error signals, cleanup semantics, useful invariants, and local style.

          While reviewers run, do your own narrow inspection if useful. After they return, synthesize the feedback into:
          - fixes worth doing now;
          - optional improvements;
          - feedback to ignore or defer, with a short reason.

          Do not blindly apply every reviewer suggestion.

          Autofix mode: if the invocation contains the exact word `autofix`, treat it as work control, not cleanup scope. Remove it before deciding the cleanup target. After synthesis, apply only fixes worth doing now, validate, and summarize. Do not apply optional improvements unless explicitly requested. If there are no fixes worth doing now, do not edit.

          Without autofix mode, ask before applying fixes unless I already told you to address review feedback. When you ask, end with a compact numbered menu so I can respond with a number. Use wording suited to the findings, but include these choices when applicable:

          ```text
          Reply with [1], [2], or further instructions:
          [1] Apply only the fixes worth doing now.
          [2] Apply the fixes worth doing now plus optional improvements.
          ```

          Additional scope or focus from the slash command invocation:

          $@
        MD
      ),
      Prompts::Template.new(
        name: "parallel-research",
        description: "Parallel subagents research",
        argument_hint: nil,
        file_path: nil,
        content: <<~'MD'
          Launch parallel research subagents to build a grounded answer to the current question or decision.

          Use fresh context, not forked context, unless I explicitly ask for forked context. Researchers should inspect sources directly instead of relying on the main conversation history.

          Pick research-shaped profiles from `~/.tart/agents` and `<cwd>/.tart/agents` when they exist (a profile pins model, tools, context, and stance); otherwise use the `worker` builtin with a read-only research brief — no edits. Split the angles across profiles:

          - External evidence: official docs, specs, release notes, benchmarks, issue threads, standards, ecosystem moves, recent changes, and primary explanations.
          - Local code context: the repository's relevant files, existing implementation patterns, repo constraints, tests, and files that would be affected.
          - Practical tradeoffs: options, risks, edge cases, maintenance cost, and what would be easiest to validate.

          Give each subagent a distinct angle. Unless I specify angles, use those three.

          Adapt the angles when the question calls for it:
          - Library/API questions: include official docs and recent examples.
          - Architecture decisions: include local module boundaries, dependency direction, and migration cost.
          - Debugging questions: include likely failure modes, local call paths, and exact error evidence.
          - UI/product questions: include user flow, accessibility, design precedent, and implementation constraints.
          - Time-sensitive topics: include a recent-developments angle and prefer current sources.

          Prefer two or three strong subagents over many vague ones. The parent agent should frame the question and assign angles; the child agents should research, not invent broad plans.

          Launch every angle at once with `subagent({ agent: "<profile-or-worker>", task: "<angle brief>", async: true })` and return control immediately; native completion notifications wake you as each subagent lands — never sleep and never poll for them.

          Ask each subagent to return concise findings with evidence:
          - file paths and line ranges for local findings
          - source links for external findings
          - confidence level and gaps
          - recommended next step or decision implication

          Do not ask subagents to edit files. This is a research pass only unless I explicitly ask for implementation.

          After the subagents return, synthesize the answer into:
          - what we know
          - what the local codebase implies
          - tradeoffs and risks
          - gaps or assumptions
          - the recommended next move

          If findings disagree, call out the disagreement instead of smoothing it over.

          $@
        MD
      ),
      Prompts::Template.new(
        name: "parallel-review",
        description: "Parallel subagents review",
        argument_hint: nil,
        file_path: nil,
        content: <<~'MD'
          Launch parallel reviewers for an adversarial review of the current work.

          Use fresh context, not forked context, unless I explicitly ask for forked context. Reviewers should inspect the repository, relevant instructions, and current diff directly from files and commands. Do not rely on the main conversation history.

          Give each reviewer a distinct angle. Generate the angles dynamically from the user's intent, the plan, the implemented code, and the current diff. If I specify angles, use mine. Otherwise, choose the highest-value review angles for this specific work.

          These are examples, not fixed defaults:

          1. Correctness and regressions
             Check whether the change satisfies the request, preserves existing behavior, handles edge cases, and avoids hidden runtime failures.

          2. Tests and validation
             Check whether tests or validation were added at the right layer, whether assertions are meaningful, and whether the chosen verification commands are enough.

          3. Simplicity and maintainability
             Check for unnecessary complexity, duplicate structure, single-use wrappers, brittle abstractions, confusing names, verbosity, and cleanup that is clearly worth doing.

          Choose or adapt angles when the work calls for it:
          - Type-heavy changes: include type safety, source-of-truth types, casts, and error-boundary discipline.
          - UI-heavy changes: include UX, accessibility, copy, and visual quality.
          - Security-sensitive changes: include unsafe input/output handling, auth boundaries, privacy, and data exposure.
          - Docs-heavy changes: include clarity, accuracy, completeness, reader flow, and non-robotic prose.
          - Large multi-file changes: consider a fourth reviewer for structural friction, module boundaries, and testability.

          Prefer three strong reviewers over many vague reviewers.

          Launch every reviewer at once with `subagent({ agent: "reviewer", task: "<angle brief>", async: true })` — a custom review profile from `~/.tart/agents` or `<cwd>/.tart/agents` may replace the builtin — and return control immediately; native completion notifications wake you as each reviewer lands. Never sleep and never poll for them.

          Give every reviewer a specific task prompt naming its angle. Ask reviewers to return concise, evidence-backed findings with file/line references and suggested fixes. Filter on evidence, not severity: a finding must be concrete and current within the named review target, and supported by source proof, a test or repro, or a contract contradiction. For a diff review, require that the issue is caused or made reachable by that diff. Label findings P0/P1/P2. P0 blocks merge. P1 should be fixed before release. P2 is report-only. End each review with `Merge verdict: BLOCK`, `Merge verdict: OK`, or `Merge verdict: OK with notes`. If nothing qualifies, ask the reviewer to say exactly `No issues found.` The response should be review feedback, not a context summary. Reviewers must not edit files unless I explicitly ask for a writer pass.

          Do not default first-pass reviews to `blockers only`. That phrase is valid only for final pre-merge re-checks after P1/P2 findings are already inventoried, or for explicit emergency hotfix lanes where non-blocking findings are intentionally deferred.

          For a targeted follow-up review, ask only whether the named finding was resolved, whether the fix introduced a new defect in the fix blast radius, and whether prior P1/P2 notes still stand. For bot or PR-comment triage, classify each comment as VALID, STALE, INVALID, or OUT-OF-POLICY against current HEAD, then assign P0/P1/P2 only to VALID comments.

          While reviewers run, do your own narrow inspection if useful. After they return, synthesize the feedback into:
          - fixes worth doing now
          - optional improvements
          - feedback to ignore or defer, with a short reason

          Do not blindly apply every reviewer suggestion.

          Autofix mode: if the invocation contains the exact word `autofix`, treat it as work control, not review scope. Remove it before deciding the review target. After synthesis, apply only fixes worth doing now, validate, and summarize. Do not apply optional improvements unless explicitly requested. If there are no fixes worth doing now, do not edit.

          Without autofix mode, ask before applying fixes unless I already told you to address review feedback. When you ask, end with a compact numbered menu so I can respond with a number. Use wording suited to the findings, but include these choices when applicable:

          ```text
          Reply with [1], [2], or further instructions:
          [1] Apply only the fixes worth doing now.
          [2] Apply the fixes worth doing now plus optional improvements.
          ```

          Additional review target or focus from the slash command invocation:

          $@

          If the invocation provides a URL, issue link, file path, plan path, or freeform focus, treat it as the primary review scope. Read or fetch that target before assigning reviewer angles, and pass the target explicitly into each reviewer task.
        MD
      ),
      Prompts::Template.new(
        name: "review-loop",
        description: "Review/fix loop until clean",
        argument_hint: nil,
        file_path: nil,
        content: <<~'MD'
          Run a parent-orchestrated review loop for the requested work.

          Keep the parent session as the loop controller and final decision-maker. Child subagents must receive concrete role-specific tasks; they must not run subagents or manage the loop themselves.

          Default to a maximum of 3 review rounds unless I specify a different cap. Count a review round each time fresh-context reviewers inspect the current diff after a worker pass. Stop early when reviewers find no P0 findings, no P1 fixes worth doing now, and no approved P2 notes that should be handled in this loop.

          If the invocation includes an implementation request, first launch one async `worker` to implement the approved scope. If the current diff is already the target, start with review. Launch the worker with `subagent({ agent: "worker", task: "<delivery slice>", async: true })`; when the work depends on inherited decisions from this conversation, the `oracle` builtin runs from a fork of it instead. Use only one writer against the active worktree at a time unless I explicitly ask for isolated worktrees.

          As a conservative orchestration policy, do not put a tight tool-call cap on implementation or fix workers — count limits measure activity, not delivery safety. Give each writer a narrow delivery slice and an outer elapsed deadline (`timeout_ms`) with enough margin. Before that deadline, ask for a checkpoint after the current tool call returns: changed files, build/test state, remaining work, and commit or PR state. An elapsed timeout is not a mutation-safe boundary and must not be the checkpoint trigger. Never sleep and never poll for a running child: native completion notifications wake you when it lands.

          For each review round, launch fresh-context `reviewer` agents in parallel with `subagent({ agent: "reviewer", task: "<angle brief>", async: true })`. Reviewers must inspect the repository, relevant instructions, and current diff directly from files and commands. They must not rely on the main conversation history and must not edit files.

          Tell reviewers to filter on evidence, not severity. They should report only concrete current issues caused or made reachable by the target diff, with source proof, a test or repro, or a contract contradiction. Ask them to label findings P0/P1/P2 and end with `Merge verdict: BLOCK`, `Merge verdict: OK`, or `Merge verdict: OK with notes`. P0 blocks merge. P1 should be fixed before release. P2 is report-only. Use `blockers only` only for final pre-merge re-checks after P1/P2 findings are already captured, or for explicit emergency hotfix lanes.

          Choose review angles from the actual change. Common angles are correctness/regressions, tests/validation, and simplicity/maintainability. Add security, performance, docs/API contracts, or user-flow validation when the work calls for it. Prefer three strong reviewers over many vague reviewers.

          After reviewers return, synthesize their feedback into:
          - P0 blockers or scope/product/architecture decisions that need user approval;
          - P1 fixes worth doing now;
          - P2 report-only notes or optional improvements;
          - feedback to ignore or defer, with a short reason.

          Do not blindly apply every reviewer suggestion. If reviewers surface an unapproved product, scope, or architecture decision, pause and ask me before launching a fix worker.

          When the async implementation worker completes, treat its handoff as the transition into review, not as final completion, unless I explicitly asked for worker-only work, review-only output, or to stop after implementation.

          When there are fixes worth doing now and the loop is implementation-authorized, launch one async `worker` to apply only those synthesized fixes. Ask it to preserve the approved scope, run focused validation, and report changed files, commands run with exit codes, validation evidence, surprises, and anything left undone.

          After a fix worker returns, run another review round only when it made material changes or addressed non-trivial findings. Do not keep looping for optional polish, speculative improvements, or findings already deferred by the parent.

          For a targeted follow-up review, ask only three questions: whether the named finding was resolved, whether the fix introduced a new concrete defect in the fix blast radius, and whether prior P1/P2 notes still stand. End with a fix verdict and the merge verdict.

          Stop and summarize when one of these is true:
          - reviewers find no P0 blockers or P1 fixes worth doing now;
          - remaining feedback is optional, speculative, or intentionally deferred;
          - reviewers surface an unapproved decision that needs me;
          - the max review-round cap is reached.

          On completion, inspect the final diff yourself, run or confirm focused validation where appropriate, and summarize the loop: rounds run, fixes applied, validation, remaining deferred items, and why the loop stopped.

          Additional target, implementation request, max-iteration cap, or review focus from the slash command invocation:

          $@
        MD
      )
    ].map(&:freeze).freeze

    module_function

    # The gate-on builtin tier merge (bin/tart's interactive boot, BEFORE
    # build_surface): the six builtins join lowest — a user/project
    # template with the same name replaces the builtin outright, so the
    # Prompts first-loaded-wins rule never sees a collision (the gate pins
    # both the override and the kept builtins). The merged Array is
    # name-sorted — the Prompts.load display order. Returns a new Array.
    def merge_workflow_templates(templates)
      names = templates.map(&:name)
      (WORKFLOW_TEMPLATES.reject { |template| names.include?(template.name) } + templates).sort_by(&:name)
    end
  end
end
