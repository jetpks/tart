# frozen_string_literal: true

module Tart
  module Agent
    # Project-context discovery (port of pi's resource-loader.ts:182-273,
    # loadContextFileFromDir + findShadowedContextFile +
    # loadProjectContextFiles): the per-directory first-match candidates,
    # the global agent-dir file, the ancestor walk (root-most first), and
    # the linked-worktree shadowing rule. Found files ride the system
    # prompt's <project_context> section ({SystemPrompt} context_files).
    module ContextFiles
      # pi loadContextFileFromDir :183 — first existing regular file wins.
      CANDIDATES = %w[AGENTS.override.md AGENTS.md AGENTS.MD CLAUDE.md CLAUDE.MD].freeze

      module_function

      # pi loadProjectContextFiles :232-273: the agent dir's file first,
      # then cwd → filesystem root, root-most first, deduped by path,
      # shadowed copies skipped.
      def load(cwd:, agent_dir:)
        resolved_cwd = File.expand_path(cwd)
        files = []
        seen = {}

        global = from_dir(agent_dir)
        if global
          files << global
          seen[global[:path]] = true
        end

        ancestors = []
        shadowed = find_shadowed(resolved_cwd)
        current = resolved_cwd
        loop do
          file = from_dir(current)
          # Compare the directory's real path, not the file's: a worktree
          # AGENTS.md symlinking the main repo's file resolves to the
          # shadowed path itself (pi :257-261).
          shadowed_here = shadowed && file &&
            File.join(canonicalize(current), File.basename(file[:path])) == shadowed
          if file && !shadowed_here && !seen[file[:path]]
            ancestors.unshift(file)
            seen[file[:path]] = true
          end

          parent = File.dirname(current)
          break if parent == current

          current = parent
        end

        files + ancestors
      end

      # pi loadContextFileFromDir :182-206: the directory's first candidate
      # that exists as a regular file, BOM-stripped.
      def from_dir(dir)
        CANDIDATES.each do |name|
          path = File.join(dir, name)
          next unless File.file?(path)

          return {path:, content: File.read(path).sub(/\A\xEF\xBB\xBF/, "")}
        end
        nil
      end

      # pi findShadowedContextFile :211-230: when cwd sits in a linked
      # worktree whose main checkout carries its own context file, that
      # main copy's canonical path — the ancestor walk skips it.
      def find_shadowed(cwd)
        git_paths = find_git_paths(cwd)
        return nil unless git_paths

        common_git_dir = canonicalize(git_paths[:common_git_dir])
        worktree_root = canonicalize(git_paths[:repo_dir])
        main_repo_root = File.dirname(common_git_dir)
        # False for an ordinary repo (the two are the same dir) and for a
        # sibling worktree whose main repo is not an ancestor (pi :221-222).
        return nil unless worktree_root.start_with?("#{main_repo_root}#{File::SEPARATOR}")
        # The dir holding the common git dir must itself be checked out
        # from the same repo — not a bare layout (proj/.bare + proj/main)
        # or a submodule gitdir (pi :224-226).
        return nil unless canonicalize(File.join(main_repo_root, ".git")) == common_git_dir

        main_file = from_dir(worktree_root)
        main_file && File.join(main_repo_root, File.basename(main_file[:path]))
      end

      # pi findGitPaths (footer-data-provider.ts:16-50): the nearest .git —
      # a directory (ordinary repo: common git dir is .git itself) or a
      # file ("gitdir: <path>", linked worktree: the commondir file picks
      # the shared git dir). nil when no .git exists up the tree.
      def find_git_paths(cwd)
        dir = cwd
        loop do
          git_path = File.join(dir, ".git")
          if File.exist?(git_path)
            if File.file?(git_path)
              target = File.read(git_path).strip
              return nil unless target.start_with?("gitdir: ")

              git_dir = File.expand_path(target.delete_prefix("gitdir: ").strip, dir)
              return nil unless File.file?(File.join(git_dir, "HEAD"))

              commondir_path = File.join(git_dir, "commondir")
              common_git_dir = File.file?(commondir_path) ? File.expand_path(File.read(commondir_path).strip, git_dir) : git_dir
              return {repo_dir: dir, common_git_dir:}
            elsif File.directory?(git_path)
              return nil unless File.file?(File.join(git_path, "HEAD"))

              return {repo_dir: dir, common_git_dir: git_path}
            end
          end

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      end

      # pi canonicalizePath (utils/paths.ts:28) — realpath through
      # symlinks; `git worktree add` writes the .git file's gitdir: target
      # in realpath form while cwd may still be symlinked (macOS /tmp).
      def canonicalize(path)
        File.realpath(path)
      rescue Errno::ENOENT
        path
      end
    end
  end
end
