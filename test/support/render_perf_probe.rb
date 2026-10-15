# frozen_string_literal: true

# I58 render-perf instrument — the default-off INTERNAL timing preload for
# tart (the spec-time scratch form at tmp/render-perf-calib/instrument.rb,
# committed as the render-perf-probe gate's tart-side instrument). Loaded
# via RUBYOPT -r<abs>/render_perf_probe.rb with TART_PERF_OUT set (the rig
# scenario env carrier); with neither set it installs NOTHING (default
# off — the suite and every other gate run untouched). Self-installs
# lazily once tart's classes exist, prepending zero-behavior-change
# timing wrappers:
#
#   - Render::Chat#render_frame      -> "render" records (md_ms, disp_ms,
#                                       widget_ms + context counters)
#   - Render::Chat#display_lines,
#           Render::Chat#build_widget -> accumulated into the CURRENT
#                                       frame's record (disp/widget)
#   - Render::Transcript.markdown_lines / reasoning_lines -> accumulated
#     into the CURRENT frame's record (Thread-local accumulator; only the
#     frame-loop fiber sets it, so enqueue-path conversions are excluded)
#   - TUI::Session#draw              -> "draw" records (the ratatui cell
#     diff + terminal write — "the diff writer")
#
# Records are JSONL, one per event; the analyzer (the render-perf-probe
# bin) pairs a render record with the nearest following draw record to
# form a frame.
#
# NOTE: no `require` of anything — this file loads pre-bundler via
# RUBYOPT; requiring stdlib default gems there activates them ahead of
# the Gemfile pins and breaks `bundle exec` (json 3.1.0 vs 3.0.2,
# probed live at the calibration). The record emitter hand-formats JSON
# (all values numeric/boolean/literal).
#
# NOTE: Kernel#require is NOT hooked for the install: ruby 4.0's
# bundled_gems + zeitwerk both wrap it and a prepended super-chain
# NoMethodErrors through their re-defined require (probed live at the
# calibration). A watcher thread polls for the classes instead.

module RenderPerfProbe
  OUT = ENV["TART_PERF_OUT"] ? File.open(ENV["TART_PERF_OUT"], "a") : nil
  OUT&.sync = true

  class << self
    def enabled? = !OUT.nil?

    def installed? = @installed ||= false

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def num(v) = format("%.3f", v)

    def record(hash)
      pairs = hash.map do |k, v|
        case v
        when nil then "\"#{k}\":null"
        when true, false then "\"#{k}\":#{v}"
        when Numeric then "\"#{k}\":#{num(v)}"
        else "\"#{k}\":#{v.to_s.inspect}"
        end
      end
      OUT.puts("{#{pairs.join(",")}}")
    rescue StandardError
      nil
    end

    def ready?
      defined?(Tart::Render::Chat) && defined?(Tart::Render::Transcript) &&
        defined?(Tart::TUI::Session)
    end

    def install
      return if installed?

      @installed = true
      Tart::Render::Chat.prepend(ChatWrap)
      Tart::Render::Transcript.singleton_class.prepend(TranscriptWrap)
      Tart::TUI::Session.prepend(SessionWrap)
    end
  end

  module ChatWrap
    def render_frame
      acc = {md: 0.0, md_calls: 0, disp: 0.0, widget: 0.0}
      prev = Thread.current[:_perf_acc]
      Thread.current[:_perf_acc] = acc
      t0 = RenderPerfProbe.mono
      begin
        super
      ensure
        Thread.current[:_perf_acc] = prev
        RenderPerfProbe.record(
          type: "render",
          t0: t0,
          ms: (RenderPerfProbe.mono - t0) * 1000,
          md_ms: acc[:md] * 1000,
          md_calls: acc[:md_calls],
          disp_ms: acc[:disp] * 1000,
          widget_ms: acc[:widget] * 1000,
          transcript_lines: @transcript_state.respond_to?(:lines) ? @transcript_state.lines.size : -1,
          live_bytes: @live.to_s.bytesize,
          reasoning_bytes: @reasoning.to_s.bytesize,
          busy: (begin
            busy?
          rescue StandardError
            nil
          end)
        )
      end
    end

    def display_lines
      t0 = RenderPerfProbe.mono
      result = super
      if (acc = Thread.current[:_perf_acc])
        acc[:disp] += RenderPerfProbe.mono - t0
      end
      result
    end

    def build_widget
      t0 = RenderPerfProbe.mono
      result = super
      if (acc = Thread.current[:_perf_acc])
        acc[:widget] += RenderPerfProbe.mono - t0
      end
      result
    end
  end

  module TranscriptWrap
    [:markdown_lines, :reasoning_lines].each do |name|
      define_method(name) do |*args, **kwargs|
        t0 = RenderPerfProbe.mono
        result = super(*args, **kwargs)
        if (acc = Thread.current[:_perf_acc])
          acc[:md] += RenderPerfProbe.mono - t0
          acc[:md_calls] += 1
        end
        result
      end
    end
  end

  module SessionWrap
    def draw(widget)
      t0 = RenderPerfProbe.mono
      super
    ensure
      RenderPerfProbe.record(type: "draw", t0: t0, ms: (RenderPerfProbe.mono - t0) * 1000)
    end
  end

  # Lazy install: a watcher thread polls for the classes (the umbrella
  # `require "tart"` defines them eagerly, top to bottom) and prepends the
  # wrappers as soon as all three exist — before any instance is built
  # (bin/tart constructs the surface only after the umbrella require
  # returns; the watcher fires mid-require, between file boundaries).
  if enabled?
    Thread.new do
      loop do
        break if RenderPerfProbe.ready?

        sleep 0.02
      end
      RenderPerfProbe.install
    end
  end

  at_exit { OUT&.close }
end
