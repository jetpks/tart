# frozen_string_literal: true

module Tart
  module Tools
    # Serializes file mutation operations targeting the same file (port of
    # pi's file-mutation-queue.ts). Operations for different files still run
    # in parallel; queues are keyed by the file's real path when it exists,
    # by the resolved path otherwise.
    #
    # THE NAMED MUTEX EXEMPTION under the owner concurrency law (2026-11-21,
    # PR-#28 review — "Mutexes are defensible ONLY with a named, specific
    # reentrancy concern"), owner-ratified via the I107 spec's OQ2: these
    # are the ONLY two surviving Mutex allocations in lib/, and the concern
    # they name is same-file mutation serialization ACROSS THE THREE CALL
    # SEATS (the reactor child task, the bare minitest thread, the
    # subagents in-process bare drive). An async primitive cannot stand in:
    # every async wait primitive rides the fiber scheduler, and the bare
    # seats have none (Async::Semaphore#wait calls Fiber.scheduler
    # .transfer — semaphore.rb — which crashes off-reactor). The critical
    # sections hold only regular-file IO, which never parks a fiber on
    # this platform, so no fiber can deadlock on its own yield inside one.
    module FileMutationQueue
      REGISTRY_MUTEX = Mutex.new
      private_constant :REGISTRY_MUTEX

      module_function

      def with(file_path)
        key = queue_key(file_path)
        mutex = REGISTRY_MUTEX.synchronize do
          (@queues ||= {})[key] ||= Mutex.new
        end
        mutex.synchronize { yield }
      end

      def queue_key(file_path)
        resolved = File.expand_path(file_path)
        File.realpath(resolved)
      rescue Errno::ENOENT, Errno::ENOTDIR
        resolved
      end
    end
  end
end
