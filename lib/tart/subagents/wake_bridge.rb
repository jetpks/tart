# frozen_string_literal: true

module Tart
  module Subagents
    # The interactive wake ferry (I48 §2.6): Manager/Supervisor kicks
    # cross onto the reactor through the TUI session's synthetic-event
    # channel — the block rides as a synthetic Proc and the boot's
    # kernel.on_event rail asyncs it. Session#push_event is
    # thread-safe; the rail no-ops the kick when a run is in flight.
    def self.wake_bridge(session)
      KernelBridge.new(->(block) { session.push_event(block) })
    end
  end
end
