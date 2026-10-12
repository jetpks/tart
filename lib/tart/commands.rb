# frozen_string_literal: true

require "json"
require_relative "models"

module Tart
  module Commands
    # Slash commands (BRIEF §3): the builtin table, dispatch, and
    # /skill:<name> expansion — pi's routing shape with the port's reduced
    # builtin set.
    #
    # Routing (pi modes/interactive/interactive-mode.ts submit path
    # :3200-3442): builtins are matched at the top of submit, before any
    # agent call; text matching no builtin falls through to normal
    # submission — the model receives it as plain text (pi: an unknown
    # /command is just a message). Match shapes per pi: /new and /quit are
    # exact (:3305-3308, :3347-3350), /compact takes optional trailing
    # args (:3310-3313). The port's additions (/skills /settings /help)
    # print through the chat surface — the port has no selector UI for
    # pi's /settings menu (recorded reductions).
    #
    # Skill expansion (pi core/agent-session.ts _expandSkillCommand
    # :2152-2175) happens in the queueing path regardless of streaming —
    # an unknown skill passes through as plain text (:2155); the expanded
    # block is what the model receives and what the session records.
    #
    # The builtin set (I27 adds /model — the port's reduction count is
    # down to 16 of pi's published builtins: tree, scoped-models,
    # export, import, share, bug, copy, name, session, changelog,
    # hotkeys, fork, clone, trust, login, logout, reload — each cut
    # bound to a feature the port lacks, itemized in the lane's
    # deviation table). /thinking (pi slash-commands.ts:23, "Set
    # thinking level", argumentHint <level>) — the level drives the
    # footer segment and the editor border color; /model (pi
    # slash-commands.ts, argumentHint <provider/model>) switches the
    # chat model against the models.json catalog.
    BUILTINS = {
      "new" => {description: "Start a new session"},
      "compact" => {description: "Manually compact the session context", args: true},
      "resume" => {description: "Resume a different session"},
      "model" => {description: "Switch the chat model", args: true, argument_hint: "<provider/model>"},
      "skills" => {description: "List loaded skills"},
      "settings" => {description: "Show resolved settings"},
      "thinking" => {description: "Set thinking level", args: true},
      "help" => {description: "Show the builtin commands"},
      "quit" => {description: "Quit tart"}
    }.freeze

    module_function

    # The builtin a submit text invokes, or nil (pi's per-command match
    # shapes: args-taking commands match "/name ...", the rest are exact).
    def builtin_name(text)
      BUILTINS.each do |name, meta|
        return name if text == "/#{name}" || (meta[:args] && text.start_with?("/#{name} "))
      end
      nil
    end

    # pi _expandSkillCommand (:2152-2175), transcribed: the expanded block
    # is `<skill name="..." location="...">` + "References are relative to
    # <baseDir>." + the stripped body + `</skill>`, args after a blank
    # line (trimmed, pi :2156-2167); unknown skill → original text.
    def expand_skill(text, skills)
      return text unless text.start_with?("/skill:")

      space_index = text.index(" ")
      skill_name = space_index.nil? ? text[7..] : text[7...space_index]
      args = space_index.nil? ? "" : text[(space_index + 1)..].to_s.strip

      skill = skills.find { |candidate| candidate.name == skill_name }
      return text unless skill # Unknown skill, pass through

      body = Skills.strip_frontmatter(File.read(skill.file_path)).strip
      skill_block = "<skill name=\"#{skill.name}\" location=\"#{skill.file_path}\">\n" \
                    "References are relative to #{skill.base_dir}.\n\n#{body}\n</skill>"
      args.empty? ? skill_block : "#{skill_block}\n\n#{args}"
    rescue StandardError
      text # Read failure: the original text (pi emits an error, :2168-2173)
    end

    # The dispatcher wired into the chat surface at the submit seam. Every
    # agent-touching dependency is re-evaluated at dispatch time (/new
    # swaps the agent loop; the surface keeps this handler for its life).
    #
    # @param skills [Array<Skills::Skill>] loaded skills (expansion, /skills).
    # @param settings [Hash] the resolved settings (/settings).
    # @param output [Proc] renders a command-output line on the surface.
    # @param spawn [Proc] runs a block as a kernel task (agent-touching
    #   commands run on the reactor fiber, like agent.run).
    # @param agent [Proc] the current {Agent::Loop} (/compact's target).
    # @param reset [Proc] starts a fresh session (/new).
    # @param resume [Proc, nil] opens the session picker (/resume); nil
    #   (test doubles) makes /resume a no-op.
    # @param thinking [Proc] sets the session's thinking level
    #   (+call(level)+; the surface's seam; /thinking's exact-arg path,
    #   pi selectThinkingLevel).
    # @param thinking_menu [Proc, nil] opens the thinking-level selector
    #   (bare /thinking, pi showThinkingSelector); nil = no-op.
    # @param models [Models::Config, nil] the models.json catalog
    #   (/model's exact-match resolution, pi findExactModelMatch).
    # @param model [Proc, nil] switches the chat model — +call(entry)+
    #   with a resolved catalog entry (/model <ref>, pi session.setModel).
    # @param model_menu [Proc, nil] opens the model selector —
    #   +call(seed)+ with the pre-filled search or nil (pi
    #   showModelSelector).
    # @param prompts [Array<Prompts::Template>] the loaded templates
    #   (/name expansion; empty = templates never match).
    # @param quit [Proc] exits the app (/quit).
    class Handler
      def initialize(skills:, settings:, output:, spawn:, agent:, reset:, resume: nil, thinking: nil,
        quit:, prompts: [], thinking_menu: nil, models: nil, model: nil, model_menu: nil)
        @skills = skills
        @settings = settings
        @output = output
        @spawn = spawn
        @agent = agent
        @reset = reset
        @resume = resume
        @thinking = thinking
        @quit = quit
        @prompts = prompts
        @thinking_menu = thinking_menu
        @models = models
        @model = model
        @model_menu = model_menu
      end

      # Expands /skill:<name> then /<template> text (pi agent-session.ts
      # :2005-2007 — skills first, then prompt templates; pure
      # pass-through otherwise).
      def expand_skill(text)
        Prompts.expand(Commands.expand_skill(text, @skills), @prompts)
      end

      # Dispatches a builtin (pi's submit-top if-chain); false when the
      # text matches no builtin — the caller sends it to the agent.
      def dispatch(text)
        name = Commands.builtin_name(text)
        return false unless name

        case name
        when "quit" then @quit.call
        when "new" then @reset.call
        when "compact" then @spawn.call { dispatch_compact }
        when "resume" then @resume&.call
        when "skills" then list_skills
        when "settings" then show_settings
        when "thinking" then dispatch_thinking(text)
        when "model" then dispatch_model(text)
        when "help" then show_help
        end
        true
      end

      private

      # pi handleThinkingCommand (:5145-5163): an arg sets the exact
      # level; the bare command opens pi's selector (the port's menu —
      # I27; the shift+tab cycle stays on the keybinding). An unknown
      # level is pi's showError text.
      def dispatch_thinking(text)
        arg = text.split(/\s+/, 2)[1].to_s.strip
        if arg.empty?
          @thinking_menu&.call
        elsif Settings::THINKING_LEVELS.include?(arg)
          @thinking&.call(arg)
        else
          @output.call(%(Unknown thinking level "#{arg}". Available levels: #{Settings::THINKING_LEVELS.join(", ")}.))
        end
      end

      # pi handleModelCommand (:5192-5216): no arg opens the selector;
      # an exact catalog match switches directly ("Model: <id>"
      # status through the switch seam); anything else opens the
      # selector pre-seeded with the arg (pi's initialSearchInput).
      def dispatch_model(text)
        arg = text.split(/\s+/, 2)[1].to_s.strip
        if arg.empty?
          @model_menu&.call(nil)
          return
        end

        entry = @models&.resolve(arg)
        entry ? @model&.call(entry) : @model_menu&.call(arg)
      end

      # pi handleCompactCommand (interactive-mode.ts:7080): compact now.
      # pi aborts a running turn first (session.compact → this.abort(),
      # agent-session.ts:2766) — the port dispatches builtins only when
      # idle (recorded reduction); custom instructions are unsupported by
      # the port's compaction seam (recorded reduction).
      def dispatch_compact
        if @agent.call.compact
          @output.call("✓ context compacted")
        else
          @output.call("nothing to compact (session too small)")
        end
      end

      def list_skills
        lines = @skills.map do |skill|
          marker = skill.disable_model_invocation ? " (not offered to the model)" : ""
          "#{skill.name}: #{skill.description} (#{skill.file_path})#{marker}"
        end
        @output.call(lines.empty? ? "no skills loaded" : "#{lines.size} skills:\n#{lines.join("\n")}")
      end

      def show_settings
        @output.call(JSON.pretty_generate(@settings))
      end

      def show_help
        lines = Commands::BUILTINS.map { |name, meta| "  /#{name}  #{meta[:description]}" }
        @output.call("Commands:\n#{lines.join("\n")}")
      end
    end
  end
end
