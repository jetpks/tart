# frozen_string_literal: true

require_relative "../compaction"

require "fast/uuid"
require "json"
require "securerandom"
require "fileutils"
require "time"

module Tart
  module Agent
    # The JSONL session store (port of pi's session-manager.ts, message-entry
    # subset: the header + message entries; every other entry type is out of
    # scope).
    #
    # File layout, ported from pi:
    # - one session per file: <root>/sessions/--<encoded-cwd>--/<timestamp>_<id>.jsonl
    #   (getDefaultSessionDirPath :596 + newSession's file naming :1080);
    # - line 1 is the header {type: "session", version, id, timestamp, cwd,
    #   parentSession?}; then message entries {type: "message", id, parentId,
    #   timestamp, message} chained by parentId (appendMessage :1197);
    # - the file is created on the first user/assistant message, not on the
    #   recorder's birth (_persist's _hasConversation gate :1166-1188);
    # - readers skip blank/malformed lines (parseSessionEntries :355) and
    #   reject files that do not open with a valid session header
    #   (loadEntriesFromFile :627);
    # - most-recent-session selection sorts by mtime and matches the
    #   resolved header cwd (findMostRecentSession :749).
    #
    # Ported deviations (itemized in the iteration record): pi's message
    # roles are "user"/"assistant"/"toolResult", the port's are ruby_llm's
    # "user"/"assistant"/"tool" — the recorded message is the port's actual
    # RubyLLM::Message (Message#to_h); and pi's null-content tolerance maps
    # user/assistant/toolResult content to [] (sessionEntryToContextMessages
    # :439-474), which ruby_llm rejects (Message#normalize_content only takes
    # String or nil), so the port maps it to "".
    #
    # Compaction (I08): compaction entries (pi CompactionEntry
    # session-manager.ts:91-104, appendCompaction :1260-1285) are appended
    # by the recorder on an auto-compaction, and context replay is
    # compaction-aware (pi buildContextEntries :475-513): the latest
    # compaction's summary projects to a user message wrapped in
    # Compaction::COMPACTION_SUMMARY_PREFIX/SUFFIX (pi's compactionSummary
    # projection, messages.ts:176-184), followed by the kept entries from
    # firstKeptEntryId up to the compaction (system messages skipped) and
    # everything after the compaction entry.
    module Session
      CURRENT_VERSION = 3

      module_function

      # Time-ordered session id (pi createSessionId :264 uses uuidv7).
      def uuidv7(time: Time.now)
        Fast::UUID.uuid_v7(time:)
      end

      # 8-hex entry id, collision-checked (pi generateId :275; falls back to
      # a full uuid after 100 collisions, like pi).
      def generate_id(taken)
        100.times do
          id = SecureRandom.hex(4)
          return id unless taken.include?(id)
        end
        Fast::UUID.uuid_v4
      end

      # The port's agent root (~/.tart; pi's is ~/.pi/agent, config.ts
      # getAgentDir). Overridable everywhere; tests inject tmp dirs.
      def default_root
        File.join(Dir.home, ".tart")
      end

      # pi getDefaultSessionDirPath :596: the resolved cwd encoded into one
      # safe path segment under <root>/sessions.
      def dir_path(cwd, root: default_root)
        safe_path = "--#{File.expand_path(cwd).sub(%r{\A[/\\]}, "").gsub(%r{[/\\:]}, "-")}--"
        File.join(root, "sessions", safe_path)
      end

      # pi getDefaultSessionDir :605.
      def ensure_dir(cwd, root: default_root)
        dir_path(cwd, root:).tap { |path| FileUtils.mkdir_p(path) }
      end

      # Line-oriented reader, blank/malformed lines skipped
      # (pi parseSessionEntries :355).
      def parse_entries(content)
        content.split("\n").filter_map { |line| parse_entry_line(line) }
      end

      def parse_entry_line(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      # pi loadEntriesFromFile :627: [] unless the file parses and opens with
      # a valid session header (type "session", String id).
      def load_entries(path)
        return [] unless File.exist?(path)

        entries = parse_entries(File.read(path))
        header = entries.first
        return [] unless header.is_a?(Hash) && header["type"] == "session" && header["id"].is_a?(String)

        entries
      end

      # Session header factory (pi SessionHeader :43 / newSession :1060).
      def header(id:, cwd:, parent_session: nil, timestamp: now_iso, version: CURRENT_VERSION)
        h = {type: "session", version:, id:, timestamp:, cwd: File.expand_path(cwd)}
        h[:parentSession] = parent_session if parent_session
        h
      end

      # Message entry factory (pi SessionMessageEntry :64 / appendMessage
      # :1197). +message+ is the serialized message Hash (Message#to_h).
      def message_entry(message, id:, parent_id:, timestamp:)
        {type: "message", id:, parentId: parent_id, timestamp:, message:}
      end

      # Compaction entry factory (pi CompactionEntry :91-104 /
      # appendCompaction :1260-1285), the port's entry subset (no usage,
      # fromHook, or systemMessage field). A null first-kept entry falls
      # back to the compaction entry's own id (pi's
      # `firstKeptEntryId ?? id`).
      def compaction_entry(summary:, first_kept_entry_id:, tokens_before:, details:,
                           id:, parent_id:, timestamp:)
        {
          type: "compaction", id:, parentId: parent_id, timestamp:,
          summary:, firstKeptEntryId: first_kept_entry_id || id, tokensBefore: tokens_before, details:
        }
      end

      # pi sessionEntryToContextMessages :439 for the message subset: message
      # entries project to their message, made chat-ready (symbol keys,
      # symbol role); null/missing content is tolerated ("" on the port —
      # module doc for the [] deviation). Compaction entries project to the
      # wrapped summary (see module doc). Other entry types project to
      # nothing; malformed entries are tolerated, never fatal.
      def entry_to_context_message(entry)
        return compaction_summary_message(entry) if entry.is_a?(Hash) && entry["type"] == "compaction"
        return nil unless entry.is_a?(Hash) && entry["type"] == "message"

        message = entry["message"]
        return nil unless message.is_a?(Hash) && message["role"].is_a?(String)

        message = message.transform_keys(&:to_sym)
        message[:role] = message[:role].to_sym
        message[:content] = "" if !message.key?(:content) || message[:content].nil?
        message
      end

      # pi's compactionSummary projection (messages.ts:109-121 + :176-184):
      # the summary rides a user message wrapped in the prefix/suffix —
      # ruby_llm supports no compactionSummary role.
      def compaction_summary_message(entry)
        summary = entry["summary"]
        return nil unless summary.is_a?(String)

        {role: :user,
         content: "#{Compaction::COMPACTION_SUMMARY_PREFIX}#{summary}#{Compaction::COMPACTION_SUMMARY_SUFFIX}"}
      end

      # The context entries of +path+ projected to chat-ready attribute
      # hashes (pi buildSessionContext's message subset): what gets seeded
      # into a chat on resume. Compaction-aware (pi buildContextEntries
      # :475-513): with a compaction entry in the path, the replay is the
      # latest compaction's summary, the kept entries from firstKeptEntryId
      # up to the compaction (system messages skipped — prompt state), and
      # everything after the compaction entry; the pre-compaction summarized
      # messages are gone. Files without compaction entries replay exactly
      # as before.
      def context_messages(path)
        entries = load_entries(path)
        compaction_index = entries.rindex { |entry| entry.is_a?(Hash) && entry["type"] == "compaction" }
        return entries.filter_map { |entry| entry_to_context_message(entry) } unless compaction_index

        compaction = entries[compaction_index]
        context_entries = [compaction]
        found_first_kept = false
        entries[0...compaction_index].each do |entry|
          found_first_kept ||= entry.is_a?(Hash) && entry["id"] == compaction["firstKeptEntryId"]
          next unless found_first_kept
          next if message_entry_with_role?(entry, "system")

          context_entries << entry
        end
        context_entries.concat(entries[(compaction_index + 1)..] || [])
        context_entries.filter_map { |entry| entry_to_context_message(entry) }
      end

      def message_entry_with_role?(entry, role)
        entry.is_a?(Hash) && entry["type"] == "message" &&
          entry["message"].is_a?(Hash) && entry["message"]["role"] == role
      end

      # pi findMostRecentSession :749: *.jsonl by mtime descending; the first
      # with a valid header whose resolved cwd matches (+cwd+ nil = any).
      # Unreadable/racy paths are skipped; nothing found is nil.
      def find_most_recent(dir, cwd: nil)
        session_files(dir).each do |path|
          header = read_header(path)
          next unless header
          next if cwd && !cwd_matches?(header["cwd"], cwd)

          return path
        end
        nil
      end

      # pi SessionManager.list (session-manager.ts, the discovery shape the
      # /resume SessionSelectorComponent loads): the cwd's sessions, *.jsonl
      # by mtime descending, valid headers only, header cwd resolved to
      # +cwd+ (pi listCurrentSessions over getDefaultSessionDirPath).
      def list(cwd:, root: default_root)
        dir = dir_path(cwd, root:)
        session_files(dir).filter_map do |path|
          header = read_header(path)
          next unless header && cwd_matches?(header["cwd"], cwd)

          path
        end
      end

      # The picker's one-line label (pi SessionSelectorComponent renders
      # session.firstMessage): the first user message's text, squashed.
      # nil when the session holds none (setup-only files).
      def preview(path)
        first = load_entries(path).find do |entry|
          message_entry_with_role?(entry, "user")
        end
        return nil unless first

        content = first["message"]["content"].to_s
        squashed = content.strip.gsub(/\s+/, " ")
        squashed.empty? ? nil : squashed
      end

      # *.jsonl paths under +dir+, mtime descending (the shared discovery
      # enumeration; unreadable/racy mtimes skipped).
      def session_files(dir)
        return [] unless File.directory?(dir)

        Dir.children(dir)
          .select { |file| file.end_with?(".jsonl") }
          .map { |file| File.join(dir, file) }
          .sort_by { |path| File.mtime(path) }
          .reverse
      rescue StandardError
        []
      end

      # First parsed entry, or nil unless it is a valid session header
      # (pi readSessionHeaderForDiscovery's discovery path).
      def read_header(path)
        return nil unless File.exist?(path)

        first = File.open(path) { |file| parse_entry_line(file.gets.to_s) }
        return nil unless first.is_a?(Hash) && first["type"] == "session" && first["id"].is_a?(String)

        first
      rescue IOError, SystemCallError
        nil
      end

      # pi sessionCwdMatches :768: a non-empty header cwd resolving to the
      # same path.
      def cwd_matches?(header_cwd, cwd)
        header_cwd.is_a?(String) && !header_cwd.empty? &&
          File.expand_path(header_cwd) == File.expand_path(cwd)
      end

      # pi's entry timestamps: new Date().toISOString() — millisecond
      # precision, UTC, Z-suffixed.
      def now_iso
        Time.now.utc.iso8601(3)
      end

      # The recorder: appends the agent's messages to a session file as they
      # occur (pi SessionManager, message subset). Agent::Loop owns the
      # recording points; this class owns the file.
      class Recorder
        attr_reader :id, :path

        # @param cwd [String] the session's working directory (header cwd +
        #   dir encoding).
        # @param root [String] the agent root (default ~/.tart; tests
        #   inject tmp dirs).
        # @param parent_session [String, nil] the previous session file's
        #   path when resuming (pi's forkSession header link :1673).
        def initialize(cwd:, root: Session.default_root, parent_session: nil)
          @cwd = File.expand_path(cwd)
          @id = Session.uuidv7
          @path = File.join(Session.ensure_dir(@cwd, root:),
            "#{Session.now_iso.tr(":.", "--")}_#{@id}.jsonl")
          @entries = [Session.header(id: @id, cwd: @cwd, parent_session:)]
          @ids = Set.new
          @leaf_id = nil
          @flushed = false
        end

        # @return [Boolean] whether the session file exists on disk yet (pi
        #   isPersisted :1166 — setup-only sessions leave no file; the exit
        #   resume hint gates on this).
        def persisted?
          @flushed
        end

        # Appends one message entry, chained to the current leaf (pi
        # appendMessage :1197). Returns the entry id.
        def append_message(message)
          entry = Session.message_entry(message.to_h,
            id: Session.generate_id(@ids),
            parent_id: @leaf_id,
            timestamp: Session.now_iso)
          @ids << entry[:id]
          @leaf_id = entry[:id]
          @entries << entry
          persist(message)
          entry[:id]
        end

        # Appends a compaction entry as a child of the current leaf and
        # advances the leaf (pi SessionManager.appendCompaction :1260-1285,
        # the port's field subset). Returns the entry id.
        def append_compaction(summary:, first_kept_entry_id:, tokens_before:, details:)
          entry = Session.compaction_entry(
            summary:,
            first_kept_entry_id:,
            tokens_before:,
            details:,
            id: Session.generate_id(@ids),
            parent_id: @leaf_id,
            timestamp: Session.now_iso,
          )
          @ids << entry[:id]
          @leaf_id = entry[:id]
          @entries << entry
          persist
          entry[:id]
        end

        private

        # pi _persist :1173: the file is created only once the session holds
        # a user or assistant message — setup-only sessions leave no file;
        # afterwards, every further entry appends one JSON line. A compaction
        # entry (+message+ nil) flushes too: a compaction always follows a
        # recorded turn, and the entry would otherwise dangle in memory.
        def persist(message = nil)
          if @flushed
            File.write(@path, entry_line(@entries.last), mode: "a")
          elsif message.nil? || %i[user assistant].include?(message.role)
            File.open(@path, "wx") do |file|
              @entries.each { |entry| file.write(entry_line(entry)) }
            end
            @flushed = true
          end
        end

        def entry_line(entry)
          "#{JSON.generate(entry)}\n"
        end
      end
    end
  end
end
