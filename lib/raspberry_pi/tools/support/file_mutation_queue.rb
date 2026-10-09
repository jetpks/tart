# frozen_string_literal: true

module RaspberryPi
  module Tools
    # Serializes file mutation operations targeting the same file (port of
    # pi's file-mutation-queue.ts). Operations for different files still run
    # in parallel; queues are keyed by the file's real path when it exists,
    # by the resolved path otherwise.
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
