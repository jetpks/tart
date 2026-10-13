# frozen_string_literal: true

require "dry/monads"

module Tart
  module Agent
    # Worker-thread bridge between the reactor fiber and blocking LLM work
    # (the ruby_llm client's Faraday/net_http I/O and tool execution are
    # blocking; the I02 kernel's reactor must never block).
    #
    # Same philosophy as the I02 poller thread: the blocking work runs on a
    # plain thread; the reactor fiber waits interruptibly on the sanctioned
    # cross-thread seam (+Async::Queue+). A kernel interrupt (Async::Cancel
    # raised at the queue wait) cancels the chat, joins the worker bounded,
    # and propagates — no orphaned task subtree.
    #
    # Everything the worker produces crosses the queue in order: streamed
    # chunks, event payloads, and one terminal item.
    #
    # I45: the terminal is a Dry::Monads::Result — Success() for a completed
    # worker, Failure(error instance) when the worker raised (the payload
    # class is the discriminator: RubyLLM::CancelledError is the cancelled
    # terminal). Streamed items stay plain values on the same queue.
    class Bridge
      include Dry::Monads::Result::Mixin

      # Bounded join on interrupt so a hung HTTP response (bounded by the
      # request timeout) cannot wedge teardown.
      JOIN_TIMEOUT = 5.0

      # Runs +work+ (a callable taking the +sink+ proc) on a worker thread.
      # Yields every item the worker sinks, in order, to this method's block.
      # Returns the terminal Result: Success() when the worker completed,
      # Failure(instance) when it raised.
      #
      # A worker exception is terminal too: the worker pushes the Failure and
      # dies, so the wait must end with the worker instead of blocking on the
      # queue forever. The Failure is returned (not yielded) — the caller's
      # error path owns it.
      #
      # On interrupt (Async::Cancel at the queue wait), calls the on_cancel
      # callback, joins the worker bounded, and re-raises.
      def run(work)
        queue = Async::Queue.new
        thread = Thread.new do
          work.call(->(item) { queue << item })
          queue << Success()
        rescue RubyLLM::CancelledError => e
          queue << Failure(e)
        rescue StandardError => e
          queue << Failure(e)
        end
        thread.report_on_exception = false

        begin
          loop do
            item = queue.pop # interruptible: Task#stop raises here
            return item if item.is_a?(Dry::Monads::Result)

            yield item
          end
        rescue Async::Cancel
          @on_cancel&.call
          raise
        ensure
          finish(thread)
        end
      end

      # Installs the callback invoked once when the waiting fiber is
      # interrupted, before the worker is joined (used to cancel the chat so
      # the worker aborts at its next checkpoint instead of running to
      # completion unobserved).
      def on_cancel(&block)
        @on_cancel = block
        self
      end

      private

      def finish(thread)
        thread.join(JOIN_TIMEOUT)
        thread.kill unless thread.join(0)
      end
    end
  end
end
