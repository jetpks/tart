# frozen_string_literal: true

module Tart
  # The scheduler wake handle — the object pushed via Fiber.scheduler#push,
  # answering the Async push contract (#alive? / #transfer). One definition;
  # the I106-era per-class redefinitions are retired.
  #
  # Data, not Struct: the handle itself is immutable. The queue it holds is
  # deliberately still mutable (shallow immutability) — #transfer is the
  # only mover.
  Wake = Data.define(:queue, :token) do
    def alive? = true

    def transfer
      queue.push(token)
    end
  end
end
