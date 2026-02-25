# frozen_string_literal: true

module AgentCore
  module Resources
    module PromptInjections
      module Sources
        class RepoDocs < Source::Base
          DEFAULT_FILENAMES = ["AGENTS.md"].freeze
          DEFAULT_WRAPPER_TEMPLATE = "<user_instructions>\n{{content}}\n</user_instructions>"

          def initialize(
            filenames: DEFAULT_FILENAMES,
            max_total_bytes: nil,
            order: 0,
            prompt_modes: PROMPT_MODES,
            wrapper_template: DEFAULT_WRAPPER_TEMPLATE,
            marker: Truncation::DEFAULT_MARKER,
            stability: :prefix
          )
            @filenames = Array(filenames).map(&:to_s).reject(&:empty?)
            @filenames = DEFAULT_FILENAMES if @filenames.empty?
            @max_total_bytes = max_total_bytes
            @order = Integer(order || 0, exception: false) || 0
            @prompt_modes = Array(prompt_modes).map { |m| m.to_sym }
            @wrapper_template = wrapper_template.to_s
            @wrapper_template = DEFAULT_WRAPPER_TEMPLATE if @wrapper_template.strip.empty?
            @marker = marker.to_s
            @stability = normalize_stability(stability)
          end

          def items(agent:, user_message:, execution_context:, prompt_mode:)
            cwd = resolve_cwd(execution_context)
            repo_root = find_repo_root(cwd) || cwd

            files = discover_files(repo_root, cwd)
            return [] if files.empty?

            body, files_meta = render_files(files, repo_root: repo_root)

            bytes_before = body.bytesize
            body_after = body
            truncated_total = false

            if @max_total_bytes
              max_bytes = Integer(@max_total_bytes, exception: false)
              if max_bytes && max_bytes >= 0
                truncated_total = bytes_before > max_bytes
                body_after = Truncation.head_marker_tail(body, max_bytes: max_bytes, marker: @marker)
              end
            end

            wrapped = @wrapper_template.gsub("{{content}}", body_after)

            [
              Item.new(
                target: :system_section,
                content: wrapped,
                order: @order,
                prompt_modes: @prompt_modes,
                id: "repo_docs",
                metadata: {
                  source: "repo_docs",
                  stability: @stability.to_s,
                  filenames: @filenames,
                  max_total_bytes: @max_total_bytes,
                  bytes_before: bytes_before,
                  bytes_after: body_after.bytesize,
                  truncated: truncated_total,
                  files: files_meta,
                }.compact,
              ),
            ]
          rescue StandardError
            []
          end

          private

          def resolve_cwd(execution_context)
            attrs = execution_context.attributes
            value = attrs[:cwd] || attrs[:workspace_dir]
            value = Dir.pwd if value.to_s.strip.empty?
            File.expand_path(value.to_s)
          rescue StandardError
            Dir.pwd
          end

          def find_repo_root(start_dir)
            dir = File.expand_path(start_dir.to_s)

            loop do
              return dir if File.exist?(File.join(dir, ".git"))

              parent = File.dirname(dir)
              return nil if parent == dir
              dir = parent
            end
          rescue StandardError
            nil
          end

          def discover_files(repo_root, cwd)
            dirs = path_dirs(repo_root, cwd)

            out = []
            dirs.each do |dir|
              @filenames.each do |name|
                path = File.join(dir, name)
                out << path if File.file?(path)
              end
            end
            out.uniq
          rescue StandardError
            []
          end

          def path_dirs(repo_root, cwd)
            root = File.expand_path(repo_root.to_s)
            current = File.expand_path(cwd.to_s)

            return [current] unless current.start_with?(root + File::SEPARATOR) || current == root

            parts = []
            dir = current
            while true
              parts << dir
              break if dir == root
              parent = File.dirname(dir)
              break if parent == dir
              dir = parent
            end

            parts.reverse
          rescue StandardError
            [cwd]
          end

          def normalize_stability(value)
            s = value.to_s.strip.downcase.tr("-", "_")
            s == "tail" ? :tail : :prefix
          rescue StandardError
            :prefix
          end

          def render_files(paths, repo_root:)
            root = File.expand_path(repo_root.to_s)

            out = +"# Repo Instructions\n"
            files_meta = []

            paths.each do |path|
              rel = path.start_with?(root) ? path.delete_prefix(root).sub(%r{\A/+}, "") : path
              out << "\n## #{rel}\n"
              content = Truncation.normalize_utf8(File.binread(path))
              out << content
              out << "\n" unless out.end_with?("\n")

              files_meta << {
                path: rel,
                bytes: content.bytesize,
                missing: false,
                truncated: false,
                max_bytes: nil,
              }.compact
            end

            [out, files_meta]
          rescue StandardError
            ["", []]
          end
        end
      end
    end
  end
end
