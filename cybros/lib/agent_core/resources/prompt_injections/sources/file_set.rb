module AgentCore
  module Resources
    module PromptInjections
      module Sources
        class FileSet < Source::Base
          DEFAULT_SECTION_HEADER = "Project Context"

          def initialize(
            files:,
            order: 0,
            prompt_modes: PROMPT_MODES,
            root_key: nil,
            total_max_bytes: nil,
            stability: :prefix,
            marker: Truncation::DEFAULT_MARKER,
            section_header: DEFAULT_SECTION_HEADER,
            substitute_variables: false,
            include_missing: true
          )
            @files = Array(files)
            @order = Integer(order || 0, exception: false) || 0
            @prompt_modes = Array(prompt_modes).map { |m| m.to_sym }
            @root_key = root_key&.to_sym
            @total_max_bytes = total_max_bytes
            @stability = normalize_stability(stability)
            @marker = marker.to_s
            @section_header = section_header.to_s.strip
            @section_header = DEFAULT_SECTION_HEADER if @section_header.empty?
            @substitute_variables = substitute_variables == true
            @include_missing = include_missing == true
          end

          def items(agent:, user_message:, execution_context:, prompt_mode:)
            root = resolve_root_dir(execution_context)
            selected_files = filter_files_for_mode(prompt_mode)

            body = +"# #{@section_header}\n"
            files_meta = []

            selected_files.each do |spec|
              rendered, meta = render_file(spec, root: root)
              next if rendered.nil? || meta.nil?

              body << "\n" unless body.end_with?("\n\n")
              body << rendered
              body << "\n" unless body.end_with?("\n")

              files_meta << meta
            end

            bytes_before = body.bytesize
            body_after = body
            truncated_total = false

            if @total_max_bytes
              max_bytes = Integer(@total_max_bytes, exception: false)
              if max_bytes && max_bytes >= 0
                truncated_total = bytes_before > max_bytes
                body_after = Truncation.head_marker_tail(body, max_bytes: max_bytes, marker: @marker)
              end
            end

            item =
              Item.new(
                target: :system_section,
                content: body_after,
                order: @order,
                prompt_modes: @prompt_modes,
                substitute_variables: @substitute_variables,
                metadata: {
                  source: "file_set",
                  stability: @stability.to_s,
                  section_header: @section_header,
                  total_max_bytes: @total_max_bytes,
                  bytes_before: bytes_before,
                  bytes_after: body_after.bytesize,
                  truncated: truncated_total,
                  files: files_meta,
                }.compact,
              )

            [item]
          rescue StandardError
            []
          end

          private

          def resolve_root_dir(execution_context)
            attrs = execution_context.attributes

            root =
              if @root_key
                attrs[@root_key]
              else
                attrs[:workspace_dir] || attrs[:cwd]
              end

            root = Dir.pwd if root.to_s.strip.empty?
            File.expand_path(root.to_s)
          rescue StandardError
            Dir.pwd
          end

          def filter_files_for_mode(prompt_mode)
            mode = prompt_mode.to_sym
            @files.select do |spec|
              h = spec.is_a?(Hash) ? AgentCore::Utils.symbolize_keys(spec) : {}
              modes = Array(h.fetch(:prompt_modes, PROMPT_MODES)).map { |m| m.to_sym }
              modes.include?(mode)
            end
          rescue StandardError
            @files
          end

          def normalize_stability(value)
            s = value.to_s.strip.downcase.tr("-", "_")
            s == "tail" ? :tail : :prefix
          rescue StandardError
            :prefix
          end

          def render_file(spec, root:)
            h = spec.is_a?(Hash) ? AgentCore::Utils.symbolize_keys(spec) : {}
            rel = h.fetch(:path).to_s
            return [nil, nil] if rel.strip.empty?

            title = h.fetch(:title, rel).to_s.strip
            title = rel if title.empty?

            path = safe_join(root, rel)

            max_bytes = h[:max_bytes]
            max_bytes = Integer(max_bytes, exception: false) if max_bytes

            content, meta =
              if path && File.file?(path)
                raw = Truncation.normalize_utf8(File.binread(path))
                raw_bytes = raw.bytesize

                if max_bytes && max_bytes.positive?
                  truncated = raw_bytes > max_bytes
                  rendered = Truncation.head_marker_tail(raw, max_bytes: max_bytes, marker: @marker)
                  [
                    rendered,
                    {
                      path: rel,
                      bytes: rendered.bytesize,
                      bytes_before: raw_bytes,
                      missing: false,
                      truncated: truncated,
                      max_bytes: max_bytes,
                    }.compact,
                  ]
                else
                  [
                    raw,
                    {
                      path: rel,
                      bytes: raw_bytes,
                      bytes_before: raw_bytes,
                      missing: false,
                      truncated: false,
                      max_bytes: max_bytes,
                    }.compact,
                  ]
                end
              elsif @include_missing
                placeholder = "[MISSING] #{rel}"
                [
                  placeholder,
                  {
                    path: rel,
                    bytes: placeholder.bytesize,
                    bytes_before: placeholder.bytesize,
                    missing: true,
                    truncated: false,
                    max_bytes: max_bytes,
                  }.compact,
                ]
              end

            return [nil, nil] if content.nil? || meta.nil?

            ["## #{title}\n#{content}", meta]
          rescue StandardError
            [nil, nil]
          end

          def safe_join(root, rel)
            root = File.expand_path(root.to_s)
            path = File.expand_path(rel.to_s, root)
            return root if path == root
            return path if path.start_with?(root + File::SEPARATOR)

            nil
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
