# frozen_string_literal: true

require "json"
require "stringio"

module Tart
  module Parity
    # Writes the run's artifacts under the out dir: summary.json (machine
    # readable: per-app completion, mock request counts vs expected, per-class
    # diff counts, candidate lines, exit code) and report.md (human readable:
    # per-run status plus the classified unified diff).
    module Report
      module_function

      def write(out_dir, scenario, summary)
        File.write(File.join(out_dir, "summary.json"), JSON.pretty_generate(summary) << "\n")
        File.write(File.join(out_dir, "report.md"), markdown(scenario, summary))
      end

      def markdown(scenario, summary)
        out = StringIO.new
        out << "# pty-tester report — #{scenario.name}\n\n"
        out << "Prompt: `#{scenario.prompt}` · expected mock requests per app: #{scenario.expected_requests}\n\n"
        out << "Exit code: **#{summary.fetch('exit_code')}**" \
          " (0 = all difference lines sanctioned, 1 = unknown-candidate lines exist, 2 = rig failure)\n\n"
        if (failure = summary["rig_failure"])
          out << "RIG FAILURE: #{failure}\n\n"
        end

        summary.fetch("runs").each do |run|
          out << "## run #{run.fetch('run')}\n\n"
          run.fetch("apps").each do |app, result|
            out << "- **#{app}**: completed=#{result.fetch('completed')}" \
              " requests=#{result.fetch('requests')}/#{result.fetch('expected_requests')}" \
              " boot_settle=#{result.fetch('boot_settle_ms')}ms" \
              " reply_settle=#{result.fetch('reply_settle_ms')}ms\n"
            out << "  - capture: #{result.fetch('capture')}\n"
            out << "  - request log: #{result.fetch('request_log')}\n"
          end
          if (diff = run["diff"])
            out << "\n### per-class diff counts\n\n"
            diff.fetch("classes").each { |klass, count| out << "- #{count}x #{klass}\n" }
            if (style = diff["style_candidates"])
              out << "\n### style differences (SGR runs on text-identical lines)\n\n"
              if style.empty?
                out << "- none — every text-identical line carries identical SGR runs\n"
              else
                out << "```\n" << style.join("\n") << "\n```\n"
              end
            end
            out << "\n### classified unified diff\n\n```diff\n"
            out << diff.fetch("unified").join("\n") << "\n```\n\n### attribution\n\n```diff\n"
            out << diff.fetch("attribution").join("\n") << "\n```\n"
          end
          out << "\n"
        end
        out.string
      end
    end
  end
end
