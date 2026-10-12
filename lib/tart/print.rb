# frozen_string_literal: true

require_relative "agent/loop"
require_relative "core/loop"

module Tart
  # Print mode (port of pi's modes/print-mode.ts, text mode): headless
  # single-shot — one prompt through the agent loop, the final response to
  # raw stdout, and an exit code for the caller (the cli lane's -p wiring).
  #
  # No TUI anywhere on the path: the loop kernel runs on a {NullSession}
  # that never yields events (pi's print mode never opens a terminal; its
  # output goes through output-guard.ts writeRawStdout:85 — raw, unbuffered).
  # Tools execute unconditionally, as everywhere (agent-loop.ts:832).
  #
  # Exit codes (print-mode.ts:145-160): 0 on success, 1 when the agent
  # stopped on error/abort (message to stderr) or an error was raised
  # (:160-162). pi's SIGTERM->143/SIGHUP->129 handlers (:51-66) are a
  # process concern, not ported into the library (parity table).
  module Print
    EXIT_OK = 0
    EXIT_ERROR = 1

    module_function

    # Runs one headless single-shot turn to completion.
    #
    # @param prompt [String]
    # @param chat [RubyLLM::Chat] configured for the endpoint.
    # @param tools [Hash{String => RubyLLM::Tool}] the gated loadout
    #   ({Tools::Registry.build}).
    # @param system_prompt [String, nil]
    # @param on_event [Proc, nil] event observer; text mode prints nothing
    #   but the final response regardless.
    # @param stdout [IO] raw stdout (unbuffered); injectable for tests.
    # @param stderr [IO] injectable for tests.
    # @return [Integer] the exit code (pi's runPrintMode return).
    def run(prompt:, chat:, tools:, system_prompt: nil, on_event: nil,
            stdout: $stdout, stderr: $stderr)
      stdout.sync = true
      agent = Agent::Loop.new(chat:, tools:, system_prompt:, on_event:)
      Core::Loop.new(session: NullSession.new).run { agent.run(prompt) }
      return error_exit(agent, stderr) if agent.last_error || agent.interrupted?

      final_response(agent, stdout)
      EXIT_OK
    rescue StandardError => e
      stderr.write("#{e.message}\n")
      EXIT_ERROR
    end

    # pi's text-mode tail (print-mode.ts:143-158): the last message decides —
    # error/aborted goes to stderr with exit 1, an assistant message's text
    # contents each go to stdout with a trailing newline, anything else
    # prints nothing.
    def error_exit(agent, stderr)
      error = agent.last_error
      stderr.write("#{error ? error.message : "Request aborted"}\n")
      EXIT_ERROR
    end

    def final_response(agent, stdout)
      final = agent.new_messages.last
      return unless final&.role == :assistant

      text_parts(final).each { |text| stdout.write("#{text}\n") }
    end

    # pi iterates the assistant message's content blocks, writing each text
    # one; the port's chat-completions path carries a String content.
    def text_parts(message)
      case (content = message.content)
      when String then [content]
      when Array then content.filter_map { |part| part[:text] if part.is_a?(Hash) }
      end
    end

    # A null terminal session for the loop kernel: blocks one poll budget
    # like a real terminal would, never yields events, never draws.
    class NullSession
      NONE = Class.new do
        def none? = true
      end.new.freeze

      def poll_event(timeout:)
        sleep(timeout)
        NONE
      end

      def synthetic_pending? = false

      def drain_synthetic
        0
      end
    end
  end
end
