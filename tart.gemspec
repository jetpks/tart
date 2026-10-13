# frozen_string_literal: true

require_relative "lib/tart/version"

Gem::Specification.new do |spec|
  spec.name = "tart"
  spec.version = Tart::VERSION
  spec.authors = ["Eric Jacobs"]
  spec.email = ["eric@ebj.dev"]

  spec.summary = "Ruby port of the pi coding-agent harness on the socketry async stack — event-loop kernel and TUI seam"
  spec.description = "Event-loop kernel for the pi port: an Async::Reactor owning timers and IO readers, a dedicated " \
    "TUI poller thread bridging input over a thread-safe queue, in-band Ctrl+C task cancellation, and adaptive " \
    "deadline-paced frame rendering. All ratatui_ruby calls are confined to the TUI interface module."
  spec.homepage = "https://github.com/jetpks/tart"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "lib/tart/render/logos/*.txt", "bin/*", "README.md"]
  end
  spec.require_paths = ["lib"]

  spec.bindir = "bin"
  spec.executables = ["tart"]

  spec.add_dependency "async", "~> 2.46"
  # Line diffs for the edit tool's details (pi uses the jsdiff package).
  spec.add_dependency "diff-lcs", "~> 1.6"
  # Parsing-boundary validation (I43 dry-rb-boundaries: the lib/tart/schemas
  # family — settings resolution, models.json, mcp.json, tool inputs).
  spec.add_dependency "dry-schema", "~> 1.16"
  spec.add_dependency "dry-validation", "~> 1.11"
  # Result-monad control flow (I45 dry-rb-flow: the agent loop's step
  # boundary and the MCP client's call surface).
  spec.add_dependency "dry-monads", "~> 1.11"
  # Typed internal shapes (I44 dry-rb-shapes: the lib/tart/shapes family —
  # the Model catalog, the resolved-settings view, the session-entry read
  # path). dry-types is declared directly: the shapes files require it.
  spec.add_dependency "dry-struct", "~> 1.8"
  spec.add_dependency "dry-types", "~> 1.9"
  # RFC 9562 uuid generation (pi createSessionId :264 / generateId :275).
  spec.add_dependency "fast-uuid", "~> 0.1.0"
  # LLM conversation loop (BRIEF §2: >= 2.1.0).
  spec.add_dependency "ruby_llm", "~> 2.1"
  # Pinned exactly: the poller thread's GVL-releasing poll_event is verified
  # for 1.5.0 only (I01 seam spike finding).
  spec.add_dependency "ratatui_ruby", "1.5.0"
end
