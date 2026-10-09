# frozen_string_literal: true

module RaspberryPi
  module Tools
    # Path resolution for the built-in tools (port of pi's path-utils.ts and
    # the resolvePath/normalizePath helpers it builds on).
    module PathUtils
      NARROW_NO_BREAK_SPACE = "\u202F"
      UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/

      module_function

      # Expand a leading ~ to the home directory, strip a leading @ (CLI
      # @file paths), and normalize unicode space variants (pi's expandPath).
      def expand_path(file_path)
        normalize(file_path, expand_tilde: true, strip_at_prefix: true, normalize_unicode_spaces: true)
      end

      # Resolve a path relative to the given cwd, handling ~ expansion and
      # absolute paths (pi's resolveToCwd).
      def resolve_to_cwd(file_path, cwd)
        expanded = expand_path(file_path)
        return expanded if absolute?(expanded)

        File.expand_path(expanded, cwd)
      end

      # pi's resolveReadPath: fall back to macOS filename variants — AM/PM
      # narrow no-break spaces, NFD form, curly apostrophes — when the
      # resolved path does not exist.
      def resolve_read_path(file_path, cwd)
        resolved = resolve_to_cwd(file_path, cwd)
        return resolved if file_exists?(resolved)

        nfd_variant = try_nfd_variant(resolved)
        [{method: :am_pm_variant}, {method: :nfd_variant}, {method: :curly_quote_variant},
         {method: :nfd_curly_quote_variant}].each do |variant|
          candidate = build_variant(resolved, nfd_variant, variant[:method])
          next unless candidate != resolved && file_exists?(candidate)

          return candidate
        end

        resolved
      end

      def file_exists?(file_path)
        File.exist?(file_path)
      end

      def absolute?(file_path)
        file_path.start_with?("/", "~")
      end

      def normalize(file_path, expand_tilde:, strip_at_prefix: false, normalize_unicode_spaces: false)
        path = file_path.strip
        path = path.delete_prefix("@") if strip_at_prefix && path.start_with?("@")
        path = path.gsub(UNICODE_SPACES, " ") if normalize_unicode_spaces
        return File.expand_path(path, Dir.home) if expand_tilde && (path == "~" || path.start_with?("~/"))

        path
      end

      def try_nfd_variant(file_path)
        file_path.unicode_normalize(:nfd)
      end

      def build_variant(resolved, nfd_variant, method)
        case method
        when :am_pm_variant then resolved.gsub(/ (AM|PM)\./i) { "#{NARROW_NO_BREAK_SPACE}#{$~[1]}." }
        when :nfd_variant then nfd_variant
        when :curly_quote_variant then resolved.gsub("'", "\u2019")
        when :nfd_curly_quote_variant then nfd_variant.gsub("'", "\u2019")
        end
      end
    end
  end
end
