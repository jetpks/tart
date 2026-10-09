# frozen_string_literal: true

module RaspberryPi
  module Tools
    # Magic-byte image MIME sniffing (port of pi's mime.ts). Detects the
    # formats the model can consume; animated PNG and CMYK JPEG are excluded
    # exactly as pi excludes them.
    module Mime
      IMAGE_TYPE_SNIFF_BYTES = 4100
      PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].freeze

      module_function

      def detect_supported_image_mime_type(buffer)
        return "image/jpeg" if starts_with(buffer, [0xff, 0xd8, 0xff]) && buffer.getbyte(3) != 0xf7
        return "image/png" if starts_with(buffer, PNG_SIGNATURE) && png? && !animated_png?(buffer)
        return "image/gif" if starts_with_ascii(buffer, 0, "GIF87a") || starts_with_ascii(buffer, 0, "GIF89a")
        return "image/webp" if starts_with_ascii(buffer, 0, "RIFF") && starts_with_ascii(buffer, 8, "WEBP")
        return "image/bmp" if starts_with_ascii(buffer, 0, "BM") && bmp?(buffer)

        nil
      end

      def detect_from_file(file_path)
        buffer = File.binread(file_path, IMAGE_TYPE_SNIFF_BYTES)
        detect_supported_image_mime_type(buffer)
      end

      def starts_with(buffer, prefix)
        prefix.each_with_index.all? { |byte, i| buffer.getbyte(i) == byte }
      end

      def starts_with_ascii(buffer, offset, text)
        text.each_byte.with_index.all? { |byte, i| buffer.getbyte(offset + i) == byte }
      end

      def png?(buffer)
        buffer.bytesize >= 16 && read_uint32_be(buffer, PNG_SIGNATURE.length) == 13 &&
          starts_with_ascii(buffer, 12, "IHDR")
      end

      def animated_png?(buffer)
        offset = PNG_SIGNATURE.length
        while offset + 8 <= buffer.bytesize
          chunk_length = read_uint32_be(buffer, offset)
          chunk_type_offset = offset + 4
          return true if starts_with_ascii(buffer, chunk_type_offset, "acTL")
          return false if starts_with_ascii(buffer, chunk_type_offset, "IDAT")

          next_offset = offset + 8 + chunk_length + 4
          return false if next_offset <= offset || next_offset > buffer.bytesize

          offset = next_offset
        end
        false
      end

      def bmp?(buffer)
        return false if buffer.bytesize < 26

        declared_file_size = read_uint32_le(buffer, 2)
        declared_file_size.zero? || declared_file_size >= buffer.bytesize
      end

      def read_uint32_be(buffer, offset)
        buffer.byteslice(offset, 4).unpack1("N")
      end

      def read_uint32_le(buffer, offset)
        buffer.byteslice(offset, 4).unpack1("V")
      end
    end
  end
end
