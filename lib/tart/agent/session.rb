# frozen_string_literal: true

require_relative "../compaction"
require_relative "../shapes/session"

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
      # a valid session header (type "session", String id) — the validity
      # gate rides the typed Shapes::SessionHeader envelope; the entries
      # themselves load verbatim (the write-path shapes are byte-frozen).
      def load_entries(path)
        return [] unless File.exist?(path)

        entries = parse_entries(File.read(path))
        return [] unless Shapes::SessionHeader.of(entries.first)

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

      # Custom-message entry factory (pi CustomMessageEntry,
      # session-manager.ts:1339-1360 — the nextTurn injection's record:
      # display-only text with no chat-message payload; +details+ nil is
      # omitted like pi's undefined). The memory recall rides this entry.
      def custom_message_entry(custom_type:, content:, display:, id:, parent_id:, timestamp:)
        {type: "custom_message", customType: custom_type, content:, display:, id:, parentId: parent_id, timestamp:}
      end

      # Compaction entry factory (pi CompactionEntry :91-104 /
      # appendCompaction :1260-1285), the port's field subset (no fromHook
      # or systemMessage field). +usage+ is the summarization call's pi
      # Usage hash ({compaction_usage}); nil omits the key (pi's optional
      # usage — JSON drops undefined). A null first-kept entry falls back
      # to the compaction entry's own id (pi's `firstKeptEntryId ?? id`).
      def compaction_entry(summary:, first_kept_entry_id:, tokens_before:, details:, usage: nil,
                           id:, parent_id:, timestamp:)
        entry = {
          type: "compaction", id:, parentId: parent_id, timestamp:,
          summary:, firstKeptEntryId: first_kept_entry_id || id, tokensBefore: tokens_before, details:
        }
        entry[:usage] = usage if usage
        entry
      end

      # The summarization call's persisted usage (pi Usage, types.ts:446 —
      # the CompactionEntry.usage field, session-manager.ts:99) from the
      # gem's Tokens readers (tokens.rb:35-37): camelCase keys, unreported
      # counts omitted; totalTokens is the component sum (pi
      # calculateContextTokens's fallback — the gem carries no total
      # reader). Nothing reported persists nothing (pi's usage-undefined
      # entries). The cost object is cut: the port carries no pricing
      # layer and no endpoint that reports one, and a fabricated zero
      # would lie (the gem's own false-zero doctrine, cost.rb:19-20).
      def compaction_usage(tokens)
        return nil unless tokens

        usage = {
          "input" => tokens.input,
          "output" => tokens.output,
          "cacheRead" => tokens.cache_read,
          "cacheWrite" => tokens.cache_write
        }
        return nil unless usage.values.compact.any?

        usage["cacheWrite1h"] = tokens.cache_write_by_ttl["1h"] if tokens.cache_write_by_ttl&.key?("1h")
        usage["reasoning"] = tokens.thinking if tokens.thinking
        usage["totalTokens"] = Compaction.calculate_context_tokens(tokens)
        usage.compact
      end

      # pi sessionEntryToContextMessages :439 for the message subset: message
      # entries project to their message, made chat-ready (symbol keys,
      # symbol role); null/missing content is tolerated ("" on the port —
      # module doc for the [] deviation). Compaction entries project to the
      # wrapped summary (see module doc). Other entry types project to
      # nothing; malformed entries are tolerated, never fatal — every gate
      # rides the typed envelopes (Shapes::MessageEntry / CompactionEntry),
      # whose .of nil-skips reproduce the guard chains exactly. Returns the
      # typed Shapes::ContextMessage; {context_messages} applies to_h at
      # the gem seam.
      def entry_to_context_message(entry)
        compaction = Shapes::CompactionEntry.of(entry)
        return compaction_summary_message(compaction) if compaction

        # pi sessionEntryToContextMessages' custom_message case
        # (session-manager.ts:437-459 → createCustomMessage → messages.ts
        # convertToLlm :161-170): the recorded recall text rides the wire
        # again on resume as a user-role message.
        if entry.is_a?(Hash) && entry["type"] == "custom_message"
          return Shapes::ContextMessage.new(role: :user, content: entry["content"].to_s)
        end

        envelope = Shapes::MessageEntry.of(entry)
        return nil unless envelope

        return bash_execution_context_message(envelope) if envelope.role == "bashExecution"

        Shapes::ContextMessage.new(envelope.message)
      end

      # pi convertToLlm's bashExecution case (messages.ts:149-160): the
      # !!-prefixed execution is SKIPPED from context; a plain ! execution
      # rides as a USER message ("Ran `<cmd>`" + the fenced output, the
      # bashExecutionToText bytes — messages.ts:82-97; ruby_llm supports
      # no bashExecution role). The per-field guards stay verbatim — the
      # field reads go through the envelope's open body hash.
      def bash_execution_context_message(envelope)
        message = envelope.message
        return nil if message["excludeFromContext"]

        text = +"Ran `#{message["command"]}`\n"
        if message["output"].is_a?(String) && !message["output"].empty?
          text << "```\n#{message["output"]}\n```"
        else
          text << "(no output)"
        end
        exit_code = message["exitCode"]
        if message["cancelled"]
          text << "\n\n(command cancelled)"
        elsif exit_code.is_a?(Integer) && exit_code != 0
          text << "\n\nCommand exited with code #{exit_code}"
        end
        if message["truncated"] && message["fullOutputPath"].is_a?(String) && !message["fullOutputPath"].empty?
          text << "\n\n[Output truncated. Full output: #{message["fullOutputPath"]}]"
        end
        Shapes::ContextMessage.new(role: :user, content: text)
      end

      # pi's compactionSummary projection (messages.ts:109-121 + :176-184):
      # the summary rides a user message wrapped in the prefix/suffix —
      # ruby_llm supports no compactionSummary role. The summary's String
      # guard stays here (the envelope's summary field is nominal).
      def compaction_summary_message(compaction)
        summary = compaction.summary
        return nil unless summary.is_a?(String)

        Shapes::ContextMessage.new(role: :user,
          content: "#{Compaction::COMPACTION_SUMMARY_PREFIX}#{summary}#{Compaction::COMPACTION_SUMMARY_SUFFIX}")
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
      # pi buildContextEntries :475-513 over a flat chronological entry
      # list: the latest compaction entry, the kept entries from its
      # firstKeptEntryId up to the compaction (system messages skipped),
      # and everything after the compaction entry; without a compaction
      # entry, the list unchanged.
      def context_entries(entries)
        compaction_index = entries.rindex { |entry| Shapes::CompactionEntry.of(entry) }
        return entries unless compaction_index

        compaction = Shapes::CompactionEntry.of(entries[compaction_index])
        context_entries = [entries[compaction_index]]
        found_first_kept = false
        entries[0...compaction_index].each do |entry|
          found_first_kept ||= entry.is_a?(Hash) && entry["id"] == compaction.first_kept_entry_id
          next unless found_first_kept
          next if message_entry_with_role?(entry, "system")

          context_entries << entry
        end
        context_entries.concat(entries[(compaction_index + 1)..] || [])
        context_entries
      end

      def context_messages(path)
        context_entries(load_entries(path)).filter_map { |entry| entry_to_context_message(entry)&.to_h }
      end

      def message_entry_with_role?(entry, role)
        envelope = Shapes::MessageEntry.of(entry)
        envelope&.role == role
      end

      # The bashExecution message factory (pi BashExecutionMessage,
      # messages.ts:28-42 — pi's exact keys: the record format, not the
      # port's ruby_llm serialization).
      def bash_execution_message(command:, output:, exit_code:, cancelled:, truncated:,
                                 full_output_path:, timestamp: now_iso, exclude_from_context: false)
        {
          role: "bashExecution", command:, output:, exitCode: exit_code, cancelled:, truncated:,
          fullOutputPath: full_output_path, timestamp:, excludeFromContext: exclude_from_context
        }
      end

      # pi findMostRecentSession :749: *.jsonl by mtime descending; the first
      # with a valid header whose resolved cwd matches (+cwd+ nil = any).
      # Unreadable/racy paths are skipped; nothing found is nil.
      def find_most_recent(dir, cwd: nil)
        session_files(dir).each do |path|
          header = read_header(path)
          next unless header
          next if cwd && !cwd_matches?(header.cwd, cwd)

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
          next unless header && cwd_matches?(header.cwd, cwd)

          path
        end
      end

      # The picker's one-line label (pi SessionSelectorComponent renders
      # session.firstMessage): the first user message's text, squashed.
      # nil when the session holds none (setup-only files).
      def preview(path)
        first = load_entries(path)
          .filter_map { |entry| Shapes::MessageEntry.of(entry) }
          .find { |envelope| envelope.role == "user" }
        return nil unless first

        content = first.message["content"].to_s
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

      # First parsed entry as the typed Shapes::SessionHeader, or nil
      # unless it is a valid session header (pi
      # readSessionHeaderForDiscovery's discovery path) — the OQ-5 API
      # move: the header is a struct now; its consumers read attributes.
      def read_header(path)
        return nil unless File.exist?(path)

        first = File.open(path) { |file| parse_entry_line(file.gets.to_s) }
        Shapes::SessionHeader.of(first)
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
          # The fork entry copy (pi forkFrom, session-manager.ts:1847-1853):
          # a fork is content-complete — every NON-header entry of the
          # parent appends VERBATIM (ids, parentIds, timestamps unchanged;
          # merged into @ids so regenerated ids cannot collide) and @leaf_id
          # threads from the last copied entry, so new appends chain from
          # the copied tail. A missing/invalid parent reads as []
          # (load_entries' parse contract): a dangling parentSession link
          # degrades to the header-only shape, never crashes. The copied
          # entries persist with the first flush (persist's
          # conversation-bearing gate holds) — a fork that never turns stays
          # setup-only.
          Session.load_entries(parent_session || "").each do |entry|
            next unless entry.is_a?(Hash) && entry["type"] != "session"

            @ids << entry["id"]
            @leaf_id = entry["id"]
            @entries << entry
          end
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

        # Appends a bashExecution message entry (pi recordBashResult
        # agent-session.ts:3879 — the executor's BashResult as a message
        # entry, same leaf chain). +message+ is the pi-shaped hash
        # ({Session.bash_execution_message}). Returns the entry id.
        def append_bash_execution(message)
          entry = Session.message_entry(message,
            id: Session.generate_id(@ids),
            parent_id: @leaf_id,
            timestamp: Session.now_iso)
          @ids << entry[:id]
          @leaf_id = entry[:id]
          @entries << entry
          persist(message)
          entry[:id]
        end

        # Appends a custom_message entry (pi appendCustomMessageEntry,
        # agent-session.ts:1144-1160 — the nextTurn injection's record, same
        # leaf chain). NON-conversation-bearing for the persist gate: a
        # recall never opens a session file alone (pi _persist's
        # _hasConversation — only user/assistant/bashExecution open it);
        # before the first flush the entry waits in @entries and rides the
        # next conversation-bearing create. Returns the entry id.
        def append_custom_message(custom_type:, content:, display:)
          entry = Session.custom_message_entry(
            custom_type:, content:, display:,
            id: Session.generate_id(@ids),
            parent_id: @leaf_id,
            timestamp: Session.now_iso,
          )
          @ids << entry[:id]
          @leaf_id = entry[:id]
          @entries << entry
          persist_custom_message
          entry[:id]
        end

        # The session's context projection (pi SessionManager
        # .buildContextEntries :475-513): the latest compaction entry, the
        # kept entries from its firstKeptEntryId onward (system messages
        # skipped), and everything after it — the as-loaded entry shape
        # (what load_entries reads back), so a live consumer reads exactly
        # the resume replay's shape.
        def context_entries
          Session.context_entries(JSON.parse(JSON.generate(@entries)))
        end

        # Appends a compaction entry as a child of the current leaf and
        # advances the leaf (pi SessionManager.appendCompaction :1260-1285,
        # the port's field subset). +usage+ is the summarization call's pi
        # Usage hash ({Session.compaction_usage}). Returns the entry id.
        def append_compaction(summary:, first_kept_entry_id:, tokens_before:, details:, usage: nil)
          entry = Session.compaction_entry(
            summary:,
            first_kept_entry_id:,
            tokens_before:,
            details:,
            usage:,
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
          elsif message.nil? || conversation_bearing?(message)
            File.open(@path, "wx") do |file|
              @entries.each { |entry| file.write(entry_line(entry)) }
            end
            @flushed = true
          end
        end

        # The custom_message persist arm: appends when flushed, never
        # creates (a recall never opens a session file alone — see
        # {append_custom_message}).
        def persist_custom_message
          return unless @flushed

          File.write(@path, entry_line(@entries.last), mode: "a")
        end

        # The file-creation gate (pi _persist's _hasConversation): user
        # and assistant messages open the file — and the bashExecution
        # record does too (pi recordBashResult → appendMessage); tool
        # results and other roles ride later appends.
        def conversation_bearing?(message)
          case message
          when Hash then message[:role] == "bashExecution"
          else %i[user assistant].include?(message.role)
          end
        end

        def entry_line(entry)
          "#{JSON.generate(entry)}\n"
        end
      end
    end
  end
end
