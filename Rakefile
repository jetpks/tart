# frozen_string_literal: true

require "rake/testtask"

# The vendored pi model catalogue (I71 R1): the offline, operator-run
# refresh — reads a LOCAL pi checkout only (ENV["PI_REPO"], default `../pi`
# beside the tart root), copies the committed data files VERBATIM and
# regenerates tart's own .manifest.json (per-file sha256, the clone's HEAD
# sha as the revision — content-hash discipline borrowed from pi's
# update-model-catalog-pin.mjs, never its network). NEVER fetches: no HTTP
# client of any kind is reachable from this file — the only sanctioned
# updater is this task, and it is offline by law.
desc "Refresh vendor/pi-models from a local pi clone (operator-run, offline; PI_REPO=<path>, default ../pi)"
task "models:vendor:refresh" do
  require "json"
  require "digest"
  require "fileutils"
  require "shellwords"

  repo = ENV["PI_REPO"] || File.expand_path("../pi", __dir__)
  data = File.join(repo, "packages/ai/src/providers/data")
  unless File.directory?(data)
    abort "models:vendor:refresh: pi checkout not found at #{repo} " \
      "(expected #{data}); point PI_REPO at a local clone of the pi repo"
  end

  out = "vendor/pi-models"
  # The non-hidden *.json set only: pi's own .manifest.json (a dotfile) is
  # NOT copied — tart records its OWN manifest over the copied files.
  files = Dir[File.join(data, "*.json")].map { |path| File.basename(path) }.sort
  abort "models:vendor:refresh: no provider data files in #{data}" if files.empty?

  FileUtils.mkdir_p(out)
  files.each do |name|
    FileUtils.cp(File.join(data, name), File.join(out, name))
  end

  revision = %x(git -C #{Shellwords.escape(repo)} rev-parse HEAD 2>/dev/null).strip
  manifest = {
    "source" => "pi (https://github.com/earendil-works/pi) packages/ai/src/providers/data",
    "revision" => revision,
    "generatedAt" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "files" => files.to_h do |name|
      [name, Digest::SHA256.hexdigest(File.binread(File.join(out, name)))]
    end
  }
  File.write(File.join(out, ".manifest.json"), JSON.pretty_generate(manifest) + "\n")
  puts "models:vendor:refresh: copied #{files.size} data files from #{repo} " \
    "(revision #{revision.empty? ? "unknown" : revision})"
end


Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb", "gems/tui-split-rig/test/**/*_test.rb"]
  t.warning = false
end

task default: :test
