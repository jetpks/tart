# frozen_string_literal: true

require "open3"

module Tart
  module Render
    # The footer state machine extracted from the chat surface (I24 wave
    # 4 — pi footer.ts over footer-data-provider.ts): the per-turn branch
    # cache (the provider's cache, reduced to per-turn invalidation), the
    # session-cumulative usage accounting, and the two-line render. The
    # branch reader is injected at construction (so tests never shell
    # out); the display facts are threaded per call ({widget} — the
    # launcher's footer_data stays on the Chat coordinator, which also
    # overlays its runtime thinking level into the threaded view). The
    # event layer drives the ops (accumulate at assistant completions,
    # reseed on replay, per-turn branch invalidation, the post-compaction
    # staleness). Unsynchronized by design: the Chat surface owns the
    # mutex.
    class Footer
      # The git branch reader (pi footer-data-provider.ts:52-70, reduced):
      # one +git symbolic-ref+ per turn, nil when not on a branch (detached
      # HEAD or no repo — pi labels detached "detached"; the port omits the
      # segment, recorded). Injected so tests never shell out.
      DEFAULT_BRANCH_READER = lambda do |cwd|
        out, _err, status = Open3.capture3("git", "--no-optional-locks", "symbolic-ref",
          "--quiet", "--short", "HEAD", chdir: cwd)
        status.success? && !out.empty? ? out.strip : nil
      end

      def initialize(branch_reader: DEFAULT_BRANCH_READER)
        @branch_reader = branch_reader
        # Footer usage state: session-cumulative token totals accumulated at
        # each assistant completion, the latest assistant usage (the context
        # numerator), and the staleness flag pi's post-compaction "?" comes
        # from (footer.ts getSessionStats / contextUsage).
        @usage_totals = {input: 0, output: 0, cache_read: 0, cache_write: 0}
        @last_usage = nil
        @usage_stale = false
        @branch = nil
        @branch_fetched = false
      end

      # The footer (AC4, pi footer.ts): line 1 the ~-contracted cwd with the
      # git branch; line 2 the token stats left and the model (plus the
      # thinking level — footer.ts:226-244) right-aligned. pi's whole
      # footer renders dim (:280-288 — the parts dimmed independently so
      # the colored context segment survives): every span is dim except
      # the context segment when it crosses the warning/error thresholds.
      def widget(data, width)
        pwd = Text.format_cwd(data[:cwd] || Dir.pwd)
        pwd = "#{pwd} (#{read_branch(data[:cwd])})" if read_branch(data[:cwd])
        # The pwd span carries the dim token ITSELF (pi footer.ts:282 —
        # theme.fg("dim", pwd)); TUI.line's array form ignores the line
        # fg, so the line-level fg: was silently dropping the color (the
        # default-fg pwd/branch defect).
        TUI.paragraph(text: [
          TUI.line(Text.clip_spans([TUI.span(pwd, fg: Theme[:dim])], width)),
          stats(data, width),
        ], wrap: false)
      end

      # Session-cumulative usage totals + the latest assistant usage (the
      # context numerator; pi's getSessionStats over session entries,
      # reduced to what the event surface carries: assistant messages).
      # Takes an assistant message (reads its +tokens+) or a bare
      # RubyLLM::Tokens (the replay's reseed from recorded counts).
      def accumulate_usage(message)
        tokens = message.respond_to?(:tokens) ? message.tokens : message
        return if tokens.nil?

        @usage_totals[:input] += tokens.input if tokens.input
        @usage_totals[:output] += tokens.output if tokens.output
        @usage_totals[:cache_read] += tokens.cache_read if tokens.cache_read
        @usage_totals[:cache_write] += tokens.cache_write if tokens.cache_write
        @last_usage = tokens
        @usage_stale = false
      end

      # Footer usage reseeds from the replayed assistant entry's recorded
      # token counts (Message#to_h merges Tokens#to_h — input_tokens,
      # output_tokens, cache_read_tokens, cache_write_tokens). Entries
      # carry usage only when the provider reported it; interrupted turns
      # may carry none (gap, itemized) — all-nil entries are skipped so
      # the boot state stays intact.
      def reseed_usage(message)
        tokens = RubyLLM::Tokens.new(
          input: message["input_tokens"], output: message["output_tokens"],
          cache_read: message["cache_read_tokens"], cache_write: message["cache_write_tokens"]
        )
        return if [tokens.input, tokens.output, tokens.cache_read, tokens.cache_write].all?(&:nil?)

        accumulate_usage(tokens)
      end

      # Per-turn branch invalidation (pi's provider cache, reduced):
      # agent_start and each submission drop the cache; the next render
      # re-reads.
      def invalidate_branch
        @branch = nil
        @branch_fetched = false
      end

      # pi: after compaction, context tokens are unknown until the next
      # LLM response (footer "?").
      def mark_usage_stale
        @usage_stale = true
      end

      # The /new + resume reset: pi's footer stats re-derive from the
      # fresh (empty) session.
      def reset_usage
        @usage_totals = {input: 0, output: 0, cache_read: 0, cache_write: 0}
        @last_usage = nil
        @usage_stale = false
      end

      private

      # The stats line as spans (footer.ts:113-153): ↑input ↓output
      # R(ead) W(rite) CH% when present, the context segment, then the
      # model right-aligned (min 2 spaces padding, stats truncated with
      # "..." when they would crowd it out). The thinking level rides the
      # right side as +model • <level>+ ONLY when the model is
      # reasoning-capable (pi footer.ts:233-244 reads
      # state.model?.reasoning; otherwise the model alone), and the
      # provider label prefixes the segment (pi :246-258 — the
      # launcher-resolved model metadata; pi's own >1-available-provider
      # gate is unimplementable without a catalog, itemized). pi's
      # "thinking off" state is unreachable through the port's level
      # resolution, itemized.
      def stats(data, width)
        totals = @usage_totals
        parts = []
        parts << "↑#{Text.format_tokens(totals[:input])}" if totals[:input].positive?
        parts << "↓#{Text.format_tokens(totals[:output])}" if totals[:output].positive?
        parts << "R#{Text.format_tokens(totals[:cache_read])}" if totals[:cache_read].positive?
        parts << "W#{Text.format_tokens(totals[:cache_write])}" if totals[:cache_write].positive?
        parts << "CH#{format("%.1f%%", cache_hit_rate)}" if cache_hit_rate

        # The model segment (pi footer.ts:233-244): +model • <level>+
        # when reasoning-capable — level "off" renders the spelled-out
        # "thinking off" (pi's literal). The provider prefix is pi's
        # >1-available-provider gate (:246-258) — the port resolves one
        # static provider, so it NEVER renders (the owner's live
        # "(openai) " finding). The level is the runtime session level
        # (/thinking), else the settings-resolved one — threaded in the
        # data view by the coordinator.
        model = data[:model] || "no-model"
        right = if data[:reasoning]
          level = data[:thinking_level]
          level == "off" ? "#{model} • thinking off" : "#{model} • #{level}"
        else
          model
        end
        left = parts.map { |part| TUI.span("#{part} ", fg: Theme[:dim]) }
        left << TUI.span(context_segment(data), fg: context_fg(data))
        pad = width - left.sum { |span| TUI.text_width(span.content) } - TUI.text_width(right)
        spans = if pad >= 2
          left + [TUI.span(" " * pad + right, fg: Theme[:dim])]
        else
          # Too wide: the stats clip (with their colors) and the model keeps
          # a two-cell margin (pi truncates statsLeft with "...").
          Text.clip_spans(left, [width - TUI.text_width(right) - 2, 0].max) + [TUI.span("… #{right}", fg: Theme[:dim])]
        end
        TUI.line(spans)
      end

      # The branch, cached until the next turn invalidates it (pi's provider
      # cache, reduced to per-turn invalidation — recorded). The fetched
      # flag makes a nil result (no repo / detached HEAD) cached too.
      def read_branch(cwd)
        return nil if @branch_reader.nil? || cwd.nil?

        unless @branch_fetched
          @branch = @branch_reader.call(cwd)
          @branch_fetched = true
        end
        @branch
      end

      # The context numerator (pi getContextUsage, agent-session.ts
      # :4237-4271): provider-reported context tokens of the latest
      # assistant usage — 0 at boot (pi's estimate 0 → the 0.0% boot
      # state), nil after a compaction until the next LLM response (pi's
      # post-compaction "?").
      def context_used
        return nil if @usage_stale
        return 0 if @last_usage.nil?

        Compaction.calculate_context_tokens(@last_usage)
      end

      # The context segment (footer.ts:134-143): "0.0%/window (auto)" at
      # boot, "pct%/window (auto)" after usage, "?/window (auto)" after a
      # compaction (pi's post-compaction "?"). Nil window renders "?"
      # alone.
      def context_segment(data)
        window = data[:context_window]
        auto = data[:auto_compact] ? " (auto)" : ""
        return "?" if window.nil?

        used = context_used
        return "?/#{Text.format_tokens(window)}#{auto}" if used.nil?

        "#{(used * 100.0 / window).round(1)}%/#{Text.format_tokens(window)}#{auto}"
      end

      def context_fg(data)
        used = context_used
        window = data[:context_window]
        return Theme[:dim] if used.nil? || !window.is_a?(Integer) || !window.positive?

        percent = used * 100.0 / window
        if percent > 90 then Theme[:error] # footer.ts:194-213
        elsif percent > 70 then Theme[:warning]
        else Theme[:dim]
        end
      end

      # pi's latestCacheHitRate (footer.ts:98-103): the latest assistant
      # usage's cacheRead share of the prompt tokens.
      def cache_hit_rate
        return nil if @last_usage.nil? || @usage_totals[:cache_read].zero? && @usage_totals[:cache_write].zero?

        prompt = [@last_usage.input, @last_usage.cache_read, @last_usage.cache_write].compact.sum
        prompt.positive? ? @last_usage.cache_read * 100.0 / prompt : nil
      end
    end
  end
end
