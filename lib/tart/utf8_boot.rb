# frozen_string_literal: true

module Tart
  # I80 encoding hygiene — Law 2, the boot UTF-8 law. A locale-less
  # process (no LANG/LC_* in its env) boots MRI with
  # Encoding.default_external = US-ASCII, so every non-ASCII ARGV element
  # arrives tagged ASCII-8BIT (BINARY) and JSON.generate warns "UTF-8
  # string passed as BINARY" on every wire round (the devstral-docs
  # failure class, 52 warnings in the dead spec run). enforce! runs ONCE
  # at the top of bin/tart's run(argv), before any parse or IO.
  #
  # It sets THIS process's Encoding values, NOT env vars (the child-env
  # law — manager.rb's locale picks — does that at spawn):
  #
  # - Encoding.default_external becomes UTF-8 unless it already is;
  #   Encoding.default_internal stays nil, never touched.
  # - ARGV retag: each element whose encoding is not UTF-8 AND whose
  #   bytes are valid UTF-8 is force_encoding(UTF_8)-retagged in place.
  #   Elements with invalid-UTF-8 bytes are left byte-identical, never
  #   mangled (a binary argv stays binary). Tags move, bytes do not —
  #   JSON.generate output is byte-identical for a valid UTF-8 string
  #   whether tagged UTF-8 or BINARY.
  module UTF8Boot
    module_function

    def enforce!(argv:)
      Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8
      argv.each_with_index do |element, index|
        next if element.encoding == Encoding::UTF_8
        next unless element.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        # ruby 4.0 freezes ARGV elements — a frozen element is retagged by
        # array-slot replacement (still byte-identical, still in place).
        argv[index] = element.frozen? ? element.dup.force_encoding(Encoding::UTF_8)
                                      : element.force_encoding(Encoding::UTF_8)
      end
      nil
    end
  end
end
