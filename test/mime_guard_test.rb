# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # I102 (KB I17 S2) — the mime nil guard: File.binread returns nil for a
  # zero-byte file, which used to crash detect_from_file with NoMethodError
  # (nil .getbyte); now it is "no image" and the read returns "" content, no
  # error envelope. NOTE (pre-existing, NOT this port's scope): the png
  # branch calls png? without its buffer argument, so a real PNG sniffs as
  # an ArgumentError at this tree's base (3e3b8a2) and at the KB lane head
  # (1ddf091) — unchanged by this port, recorded loudly instead of silently
  # "fixed".
  class MimeGuardTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-mime-guard-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def test_detect_from_file_of_zero_byte_file_is_nil
      path = File.join(@dir, "zero.log")
      File.write(path, "")
      assert_nil Tools::Mime.detect_from_file(path)
    end

    def test_detect_supported_image_mime_type_of_nil_is_nil
      assert_nil Tools::Mime.detect_supported_image_mime_type(nil)
    end

    # The muse's deterministic repro, kept green.
    def test_read_of_zero_byte_file_returns_empty_content_not_error
      path = File.join(@dir, "14-decompose.log")
      File.write(path, "")
      tool = Tools::Read.new(cwd: @dir)
      result = tool.execute(path: path)
      assert_equal "", result
      assert result.is_a?(String), "must not be an {error:} envelope: #{result.inspect}"
    end

    def test_read_of_one_byte_text_file_unaffected
      path = File.join(@dir, "one.txt")
      File.write(path, "x")
      assert_equal "x", Tools::Read.new(cwd: @dir).execute(path: path)
    end

    def test_image_sniff_still_detects_supported_formats
      assert_equal "image/jpeg", sniff([0xff, 0xd8, 0xff, 0xe0] + "JFIF".bytes)
      assert_equal "image/gif", sniff("GIF89a".bytes + [0x00] * 10)
      assert_equal "image/webp", sniff("RIFF".bytes + [0x00] * 4 + "WEBP".bytes + [0x00] * 4)
      assert_equal "image/bmp", sniff("BM".bytes + [0x00] * 24 + [0x78, 0x56, 0x34, 0x12])
    end

    def test_non_image_content_still_sniffs_nil
      assert_nil sniff("hello world\n".bytes)
      assert_nil sniff([0x00] * 16)
    end

    private

    def sniff(bytes)
      path = File.join(@dir, "sniff.bin")
      File.binwrite(path, bytes.pack("C*"))
      Tools::Mime.detect_from_file(path)
    end
  end
end
