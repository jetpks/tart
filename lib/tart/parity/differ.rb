# frozen_string_literal: true

module Tart
  module Parity
    # Line diff + attribution. Computes a minimal line edit script (LCS over
    # whole lines, stdlib DP — the captures are a screenful, ~40 lines), then
    # classifies every difference line against a Registry. A difference line
    # matching no registry class is an unknown-candidate: reported, counted,
    # and fatal for exit code 0.
    #
    # The diff is intentionally SHARP: a pure vertical shift of identical
    # content (MOTD height pushing the reply down a row) shows up as
    # -old/+new candidate pairs, not as an auto-sanctioned "alignment" class.
    class Differ
      Op = Struct.new(:kind, :line, :a_no, :b_no) # kind: :same | :del | :ins

      Classified = Struct.new(:op, :klass) # klass: class name or nil (candidate)

      attr_reader :ops, :classifications, :candidates, :per_class

      def self.diff(a_text, b_text, registry)
        new(a_text, b_text, registry)
      end

      def initialize(a_text, b_text, registry)
        @registry = registry
        @ops = Differ.ops(a_text.lines(chomp: true), b_text.lines(chomp: true))
        @classifications = @ops.reject { |op| op.kind == :same }
          .map { |op| Classified.new(op, registry.classify(op.line)) }
        @candidates = @classifications.select { |c| c.klass.nil? }
        @per_class = @classifications.group_by { |c| c.klass || "unknown-candidate" }
          .transform_values(&:size)
      end

      # True when every difference line matched a registry class.
      def clean?
        @candidates.empty?
      end

      # Unified-diff-shaped hunks (no context) over the raw lines.
      def unified
        out = []
        @ops.chunk_while { |a, b| a.kind != :same && b.kind != :same }.each do |group|
          next if group.all? { |op| op.kind == :same }

          a_from = group.first.a_no || (group.first.b_no - 1)
          b_from = group.first.b_no || (group.first.a_no - 1)
          a_len = group.count { |op| op.kind != :ins }
          b_len = group.count { |op| op.kind != :del }
          out << format("@@ -%d,%d +%d,%d @@", a_from, a_len, b_from, b_len)
          group.each do |op|
            out << case op.kind
                   when :del then "-#{op.line}"
                   when :ins then "+#{op.line}"
                   else " #{op.line}"
                   end
          end
        end
        out
      end

      private

      # Minimal edit script over whole lines (LCS dynamic programming;
      # captures are screen-sized so the n*m table is trivial).
      def self.ops(a, b)
        table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
        (a.size - 1).downto(0) do |i|
          (b.size - 1).downto(0) do |j|
            table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : [table[i + 1][j], table[i][j + 1]].max
          end
        end
        ops = []
        i = 0
        j = 0
        while i < a.size && j < b.size
          if a[i] == b[j]
            ops << Op.new(:same, a[i], i + 1, j + 1)
            i += 1
            j += 1
          elsif table[i + 1][j] >= table[i][j + 1]
            ops << Op.new(:del, a[i], i + 1, nil)
            i += 1
          else
            ops << Op.new(:ins, b[j], nil, j + 1)
            j += 1
          end
        end
        while i < a.size
          ops << Op.new(:del, a[i], i + 1, nil)
          i += 1
        end
        while j < b.size
          ops << Op.new(:ins, b[j], nil, j + 1)
          j += 1
        end
        ops
      end
    end
  end
end
