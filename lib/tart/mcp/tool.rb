# frozen_string_literal: true

require "digest"
require "dry/monads"
require "tmpdir"

require_relative "../tools/support/truncate"

module Tart
  module Mcp
    # One MCP tool wrapped as a Fast::Completions::Tool for the loadout (pi's
    # extensions/mcp/tools.ts createMcpToolDefinition + convertMcpResult):
    #
    # - wire name mcp__<server>__<tool> (createMcpToolName: sanitize, cap at
    #   64 chars, hash suffix on overflow/collision);
    # - exposure `direct` — declared to the model like any other tool. The
    #   port ships direct only (pi also has codemode/deferred/hidden;
    #   simplification itemized in the iteration record);
    # - the model-facing result is the server's text content joined by
    #   newlines, middle-truncated at 20KB with the full text saved to a temp
    #   file (pi's limitMcpContent); isError results become {error:} results;
    #   a content-less result falls back to its structuredContent as JSON.
    class Tool < Fast::Completions::Tool
      include Dry::Monads::Result::Mixin

      EXPOSURE = "direct"

      # Model-facing text of an MCP result beyond this is cut in the middle.
      OUTPUT_MAX_BYTES = 20 * 1024
      MAX_TOOL_NAME_LENGTH = 64

      attr_reader :server, :remote_name, :client

      # @param wire_name [String] the loadout/wire name (mcp__<server>__<tool>).
      # @param server [String] the configured server's name.
      # @param remote_name [String] the tool name as the server offers it.
      # @param client [Client] the connected server client.
      # @param timeout_ms [Integer, nil] per-call request timeout override.
      def initialize(wire_name:, server:, remote_name:, description:, input_schema:, client:, timeout_ms: nil)
        @wire_name = wire_name
        @server = server
        @remote_name = remote_name
        @description = description
        @input_schema = normalize_schema(input_schema)
        @client = client
        @timeout_ms = timeout_ms
      end

      def name
        @wire_name
      end

      def description
        @description
      end

      # The server's input schema, stringified with the schema metadata
      # stripped — the replaced client's schema-pipeline semantics, inlined
      # (deep stringification, then the $schema/title metadata keys dropped
      # at the top level). Declared per instance: the schema is the
      # server's, not the class's.
      def parameters_schema
        schema = deep_stringify_keys(@input_schema)
        schema.reject { |key, _| %w[$schema title].include?(key) }
      end

      # The wire declaration (the codec reads the instance): the same
      # stringified schema.
      def parameters
        parameters_schema
      end

      # The execution seam (the batch executor lands here): the MCP wire
      # speaks string keys — the provider's parsed arguments ride verbatim.
      def call(tool_call: nil, **arguments)
        execute(**arguments)
      end

      # @return [String] the model-facing text, or {error:} on failure (house
      #   SafeExecute semantics: execution failures are error tool results,
      #   cancellation always propagates). The client's Result lands here as
      #   a value: a Failure maps to {error: payload.message} — the bytes
      #   today's rescue wall produced.
      def execute(**arguments)
        outcome = client.call_tool(@remote_name, arguments, timeout_ms: @timeout_ms)
        return {error: outcome.failure.message} if outcome.failure?

        result = outcome.value!
        text = model_facing_text(result)
        result["isError"] ? {error: text} : text
      rescue Fast::Completions::CancelledError
        raise
      rescue StandardError => e
        {error: e.message}
      end

      def close
        client.close
      end

      # `mcp__<server>__<tool>`, sanitized and shortened with a hash suffix
      # when too long (pi's createMcpToolName). +taken+ reports names used by
      # a different MCP tool.
      def self.tool_name(server, remote_name, taken = ->(_name) { false })
        name = "mcp__#{server}__#{remote_name}".gsub(/[^A-Za-z0-9_]/, "_")
        return name if name.length <= MAX_TOOL_NAME_LENGTH && !taken.call(name)

        hash = Digest::SHA256.hexdigest("#{server}\0#{remote_name}")[0, 8]
        "#{name[0, MAX_TOOL_NAME_LENGTH - hash.length - 1]}_#{hash}"
      end

      private

      # MCP servers may omit `type`, and some providers reject object schemas
      # without `properties` (pi's toParameters).
      def normalize_schema(schema)
        schema = {"type" => "object", "properties" => {}}.merge(schema.to_h)
        schema["type"] ||= "object"
        schema
      end

      def deep_stringify_keys(value)
        case value
        when Hash then value.each_with_object({}) { |(key, val), out| out[key.to_s] = deep_stringify_keys(val) }
        when Array then value.map { |item| deep_stringify_keys(item) }
        when Symbol then value.to_s
        else value
        end
      end

      def model_facing_text(result)
        text = result["content"].select { |block| block.is_a?(Hash) && block["type"] == "text" }
          .map { |block| block["text"] }.join("\n")
        # Without content blocks, pi falls back to the structured content as JSON.
        text = JSON.generate(result["structuredContent"]) if text.empty? && result["structuredContent"]
        text = limit_content(text)
        return text unless text.empty? && result["isError"]

        "MCP tool #{server}/#{remote_name} returned an error"
      end

      # Keep model-facing text within OUTPUT_MAX_BYTES (pi's limitMcpContent):
      # Codex's middle-truncation format plus the temp file with the full text.
      def limit_content(text)
        truncation = Tools::Truncate.truncate_middle(text, OUTPUT_MAX_BYTES)
        return text unless truncation[:truncated]

        path = save_full_output(text)
        tokens = (truncation[:total_bytes] / 4.0).ceil
        "Warning: truncated output (original token count: #{tokens})\n" \
          "Total output lines: #{truncation[:total_lines]}\n\n#{truncation[:content]}\n\n" \
          "[Full output: #{path} (read it with offset/limit)]"
      end

      def save_full_output(text)
        path = File.join(Dir.tmpdir, "tart-mcp-#{Process.pid}-#{rand(1_000_000)}.txt")
        File.write(path, text)
        path
      end
    end
  end
end
