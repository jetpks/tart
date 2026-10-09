# frozen_string_literal: true

require_relative "lib/raspberry_pi/version"

Gem::Specification.new do |spec|
  spec.name = "raspberry-pi"
  spec.version = RaspberryPi::VERSION
  spec.authors = ["Eric Jacobs"]
  spec.email = ["eric@ebj.dev"]

  spec.summary = "Ruby port of the pi coding-agent harness on the socketry async stack — event-loop kernel and TUI seam"
  spec.description = "Event-loop kernel for the pi port: an Async::Reactor owning timers and IO readers, a dedicated " \
    "TUI poller thread bridging input over a thread-safe queue, in-band Ctrl+C task cancellation, and adaptive " \
    "deadline-paced frame rendering. All ratatui_ruby calls are confined to the TUI interface module."
  spec.homepage = "https://github.com/jetpks/raspberry-pi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*.rb", "README.md"]
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "async", "~> 2.46"
  # Pinned exactly: the poller thread's GVL-releasing poll_event is verified
  # for 1.5.0 only (I01 seam spike finding).
  spec.add_dependency "ratatui_ruby", "1.5.0"
end
