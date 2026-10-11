# frozen_string_literal: true

module Tart
  module Parity
    # Line diff + attribution. Computes a minimal line edit script (LCS over
    # whole lines, stdlib DP — the captures are a screenful, ~40 lines), then
    # classifies every difference line against a Registry. A difference line
    # matching no registry class is an unknown-candidate: reported, counted,
    # and fatal for exit code 0.
    #
    # The diff is intentionally SHARP: a pure vertical shift of identical
    # content (MOTD height pushing the reply down a row) shows up as
    # -old/+new candidate pairs, not as an auto-sanctioned "alignment" class.
    class Differ
      Op = Struct.new(:kind, :line, :a_no, :b_no) # kind: :same | :del | :ins

      Classified = Struct.new(:op, :klass) # klass: class name or nil (candidate)

      # A style-only difference: the stripped texts are identical (the
      # structural diff called the line :same) but the SGR runs differ.
      # pi_styles/tart_styles are the captured CSI sequences per side.
      StyleCandidate = Struct.new(:line, :a_no, :b_no, :pi_styles, :tart_styles)

      attr_reader :ops, :classifications, :candidates, :per_class

      def self.diff(a_text, b_text, registry)
        new(a_text, b_text, registry)
      end

      def initialize(a_text, b_text, registry)
        @registry = registry
        @ops = Differ.ops(a_text.lines(chomp: true), b_text.lines(chomp: true))
        @classifications = @ops.reject { |op| op.kind == :same }
          .map { |op| Classified.new(op, registry.classify(op.line)) }
        @candidates = @classifications.select { |c| c.klass.nil? }
        @per_class = @classifications.group_by { |c| c.klass || "unknown-candidate" }
          .transform_values(&:size)
      end

      # True when every difference line matched a registry class.
      def clean?
        @candidates.empty?
      end

      # The STYLE pass (the SGR dimension the plain capture strips): over
      # the :same ops — the lines whose TEXT is identical — the EFFECTIVE
      # per-run cell styles must match; a difference is a style candidate,
      # classified by the registry against the stripped line (a style
      # difference on a structurally-different line is unjudgeable — the
      # text diff owns it until the text matches). Styled lines align 1:1
      # with plain lines (tmux -e embeds escapes, never newlines).
      #
      # The comparison runs on EFFECTIVE styles ({effective_runs}), and
      # the SGR state CARRIES ACROSS LINES (tmux's -e writer emits state
      # CHANGES: a dim attribute set on one row emits nothing on the rows
      # that inherit it — a per-line walk misreads inherited style as
      # absence). Both captures walk with their own carried state.
      def style_candidates(styled_a, styled_b, registry)
        strip = ->(line) { line.gsub(/\e\[[0-9;?]*[a-zA-Z]/, "") }
        a_walk = Differ.walk(styled_a)
        b_walk = Differ.walk(styled_b)
        @ops.filter_map do |op|
          next unless op.kind == :same

          a_runs = a_walk[op.a_no - 1]
          b_runs = b_walk[op.b_no - 1]
          next if a_runs.nil? || b_runs.nil? || a_runs == b_runs

          candidate = StyleCandidate.new(strip.call(op.line), op.a_no, op.b_no,
            Differ.format_runs(a_runs), Differ.format_runs(b_runs))
          [candidate, registry.classify(candidate.line, style_only_context: true)]
        end
      end

      # One run's effective style: [text, fg, bg, attrs] — fg/bg the SGR
      # color spec ("2;r;g;b" / "5;n" / the plain 16 number) or nil
      # (default), attrs the sorted attribute set. The comparable form.
      Run = Struct.new(:text, :fg, :bg, :attrs)

      class << self
        # The whole capture's effective runs per line: the SGR state
        # carries across lines (the writer's diff optimization), the run
        # list resets per line (the comparable unit).
        def walk(lines)
          state = {fg: nil, bg: nil, attrs: {}}
          lines.map do |line|
            runs = []
            line.scan(/\e\[([0-9;?]*)([a-zA-Z])|([^\e]+)/).each do |params, kind, text|
              if kind == "m" # SGR
                apply_sgr(state, params)
              elsif kind || text.nil?
                next # non-SGR CSI/escapes: none survive in a settled capture
              end
              next if text.nil? || text.empty?

              attrs = state[:attrs].keys.sort
              if runs.empty? || runs.last.fg != state[:fg] || runs.last.bg != state[:bg] ||
                  runs.last.attrs != attrs
                runs << Run.new(text, state[:fg], state[:bg], attrs)
              else
                runs.last.text << text
              end
            end
            runs
          end
        end

        SGR_ATTRIBUTES = {"1" => :bold, "2" => :dim, "3" => :italic, "4" => :underline,
                          "7" => :reversed}.freeze

        def apply_sgr(state, params)
          params = params.split(";")
          params = [""] if params.empty? # \e[m = reset
          i = 0
          while i < params.size
            p = params[i]
            case p
            when "", "0" then state.update(fg: nil, bg: nil, attrs: {})
            when "39" then state[:fg] = nil
            when "49" then state[:bg] = nil
            when *SGR_ATTRIBUTES.keys then state[:attrs][SGR_ATTRIBUTES[p]] = true
            when "22", "23", "24", "27" then state[:attrs].clear # coarse: the captures never stack them
            when "38", "48"
              # The extended forms consume their whole parameter span
              # (38;5;n → 3, 38;2;r;g;b → 5) — the tail values must not
              # re-enter the plain-code path.
              mode = params[i + 1]
              spec = mode == "5" ? "c#{params[i + 2]}" : "rgb:#{params[i + 2, 3].join(';')}"
              state[p == "38" ? :fg : :bg] = spec
              i += mode == "5" ? 2 : 4
            else
              state[:fg] = p if (30..37).cover?(p.to_i) || (90..97).cover?(p.to_i)
              state[:bg] = p if (40..47).cover?(p.to_i) || (100..107).cover?(p.to_i)
            end
            i += 1
          end
        end
      end

      SGR_ATTRIBUTES = {"1" => :bold, "2" => :dim, "3" => :italic, "4" => :underline,
                        "7" => :reversed}.freeze

      def self.apply_sgr(state, params)
        params = params.split(";")
        params = [""] if params.empty? # \e[m = reset
        i = 0
        while i < params.size
          p = params[i]
          case p
          when "", "0" then state.update(fg: nil, bg: nil, attrs: {})
          when "39" then state[:fg] = nil
          when "49" then state[:bg] = nil
          when *SGR_ATTRIBUTES.keys then state[:attrs][SGR_ATTRIBUTES[p]] = true
          when "22", "23", "24", "27" then state[:attrs].clear # coarse: the captures never stack them
          when "38", "48"
            # The extended forms consume their whole parameter span
            # (38;5;n → 3, 38;2;r;g;b → 5) — the tail values must not
            # re-enter the plain-code path.
            mode = params[i + 1]
            spec = mode == "5" ? "c#{params[i + 2]}" : "rgb:#{params[i + 2, 3].join(';')}"
            state[p == "38" ? :fg : :bg] = spec
            i += mode == "5" ? 2 : 4
          else
            state[:fg] = p if (30..37).cover?(p.to_i) || (90..97).cover?(p.to_i)
            state[:bg] = p if (40..47).cover?(p.to_i) || (100..107).cover?(p.to_i)
          end
          i += 1
        end
      end

      # The report form: one line per run — the text + the style spec.
      def self.format_runs(runs)
        runs.map do |run|
          spec = [run.fg && "fg=#{run.fg}", run.bg && "bg=#{run.bg}",
                  run.attrs.any? && "attrs=#{run.attrs.join('+')}"].compact.join(",")
          "[#{spec.empty? ? 'default' : spec}]#{run.text.inspect}"
        end.join(" ")
      end

      # Unified-diff-shaped hunks (no context) over the raw lines.
      def unified
        out = []
        @ops.chunk_while { |a, b| a.kind != :same && b.kind != :same }.each do |group|
          next if group.all? { |op| op.kind == :same }

          a_from = group.first.a_no || (group.first.b_no - 1)
          b_from = group.first.b_no || (group.first.a_no - 1)
          a_len = group.count { |op| op.kind != :ins }
          b_len = group.count { |op| op.kind != :del }
          out << format("@@ -%d,%d +%d,%d @@", a_from, a_len, b_from, b_len)
          group.each do |op|
            out << case op.kind
                   when :del then "-#{op.line}"
                   when :ins then "+#{op.line}"
                   else " #{op.line}"
                   end
          end
        end
        out
      end

      private

      # Minimal edit script over whole lines (LCS dynamic programming;
      # captures are screen-sized so the n*m table is trivial).
      def self.ops(a, b)
        table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
        (a.size - 1).downto(0) do |i|
          (b.size - 1).downto(0) do |j|
            table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : [table[i + 1][j], table[i][j + 1]].max
          end
        end
        ops = []
        i = 0
        j = 0
        while i < a.size && j < b.size
          if a[i] == b[j]
            ops << Op.new(:same, a[i], i + 1, j + 1)
            i += 1
            j += 1
          elsif table[i + 1][j] >= table[i][j + 1]
            ops << Op.new(:del, a[i], i + 1, nil)
            i += 1
          else
            ops << Op.new(:ins, b[j], nil, j + 1)
            j += 1
          end
        end
        while i < a.size
          ops << Op.new(:del, a[i], i + 1, nil)
          i += 1
        end
        while j < b.size
          ops << Op.new(:ins, b[j], nil, j + 1)
          j += 1
        end
        ops
      end
    end
  end
end
