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
  # LLM conversation loop (BRIEF §2: >= 2.1.0).
  spec.add_dependency "ruby_llm", "~> 2.1"
  # Pinned exactly: the poller thread's GVL-releasing poll_event is verified
  # for 1.5.0 only (I01 seam spike finding).
  spec.add_dependency "ratatui_ruby", "1.5.0"
end
