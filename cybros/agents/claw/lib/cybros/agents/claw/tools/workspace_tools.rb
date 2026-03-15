require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

module Cybros
  module Agents
    module Claw
      module Tools
        class WorkspaceTools
          MAX_MATCHES = 200
          CODEX_PATCH_BEGIN = "*** Begin Patch".freeze
          CODEX_PATCH_END = "*** End Patch".freeze
          CODEX_UPDATE_FILE = "*** Update File: ".freeze
          CODEX_ADD_FILE = "*** Add File: ".freeze
          CODEX_DELETE_FILE = "*** Delete File: ".freeze
          CODEX_MOVE_TO = "*** Move to: ".freeze
          CODEX_END_OF_FILE = "*** End of File".freeze
          PATCH_HEADER_PREFIXES = ["--- ", "+++ "].freeze

          class PatchFormatError < StandardError; end

          def initialize(workspace_root:)
            @workspace_root = normalize_workspace_root(workspace_root)
          end

          def call(logical_tool_name:, arguments:)
            case logical_tool_name.to_s
            when "glob"
              glob(arguments)
            when "search"
              search(arguments)
            when "read"
              read(arguments)
            when "write"
              write(arguments)
            when "edit"
              edit(arguments)
            when "apply_patch"
              apply_patch(arguments)
            when "exec"
              exec(arguments)
            else
              nil
            end
          end

          private

          attr_reader :workspace_root

          def glob(arguments)
            pattern = arguments.fetch("pattern", "").to_s
            return error_result("glob requires pattern") if pattern.empty?

            matches =
              Dir.glob(pattern, base: workspace_root.to_s, sort: true)
                .select { |path| file_within_workspace?(path) }
                .uniq

            success_result(
              JSON.generate(
                {
                  "matches" => matches,
                  "truncated" => false,
                },
              ),
            )
          end

          def search(arguments)
            query = arguments.fetch("query", arguments.fetch("pattern", "")).to_s
            return error_result("search requires query") if query.empty?

            matches = []

            Dir.glob("**/*", base: workspace_root.to_s, sort: true).each do |relative_path|
              next unless file_within_workspace?(relative_path)

              absolute_path = workspace_root.join(relative_path)
              content = read_utf8_file(absolute_path)
              next if content.nil?

              content.each_line.with_index(1) do |line, line_number|
                next unless line.include?(query)

                matches << {
                  "path" => relative_path,
                  "line" => line_number,
                  "snippet" => line.chomp,
                }
                break if matches.length >= MAX_MATCHES
              end
              break if matches.length >= MAX_MATCHES
            end

            success_result(
              JSON.generate(
                {
                  "matches" => matches,
                  "truncated" => matches.length >= MAX_MATCHES,
                },
              ),
            )
          end

          def read(arguments)
            relative_path = arguments.fetch("path", "").to_s
            return error_result("read requires path") if relative_path.empty?

            absolute_path = resolve_existing_path(relative_path)
            content = read_utf8_file(absolute_path)
            return error_result("read only supports UTF-8 text files") if content.nil?

            success_result(content)
          rescue Errno::ENOENT
            error_result("read path does not exist: #{relative_path}")
          rescue SecurityError => e
            error_result(e.message)
          end

          def write(arguments)
            relative_path = arguments.fetch("path", "").to_s
            return error_result("write requires path") if relative_path.empty?

            content = arguments.fetch("content", nil)
            return error_result("write requires content") if content.nil?

            absolute_path = resolve_output_path(relative_path)
            FileUtils.mkdir_p(absolute_path.dirname)
            File.write(absolute_path, content.to_s, mode: "w", encoding: Encoding::UTF_8)

            success_result(
              JSON.generate(
                {
                  "path" => relative_path,
                  "bytes_written" => content.to_s.bytesize,
                },
              ),
            )
          rescue SecurityError => e
            error_result(e.message)
          end

          def edit(arguments)
            relative_path = arguments.fetch("path", "").to_s
            return error_result("edit requires path") if relative_path.empty?

            old_text = arguments.fetch("old_text", nil)
            return error_result("edit requires old_text") if old_text.nil? || old_text.to_s.empty?

            new_text = arguments.fetch("new_text", nil)
            return error_result("edit requires new_text") if new_text.nil?

            absolute_path = resolve_existing_path(relative_path)
            content = read_utf8_file(absolute_path)
            return error_result("edit only supports UTF-8 text files") if content.nil?

            occurrences = content.scan(Regexp.new(Regexp.escape(old_text.to_s))).length
            return error_result("edit match is ambiguous (#{occurrences} occurrences)") if occurrences != 1

            updated = content.sub(old_text.to_s, new_text.to_s)
            File.write(absolute_path, updated, mode: "w", encoding: Encoding::UTF_8)

            success_result(
              JSON.generate(
                {
                  "path" => relative_path,
                  "replacements" => 1,
                },
              ),
            )
          rescue Errno::ENOENT
            error_result("edit path does not exist: #{relative_path}")
          rescue SecurityError => e
            error_result(e.message)
          end

          def apply_patch(arguments)
            patch_text = arguments.fetch("patch", "").to_s
            return error_result("apply_patch requires patch") if patch_text.empty?

            statuses =
              if codex_patch_format?(patch_text)
                apply_codex_patch(patch_text)
              else
                apply_unified_patch(patch_text)
              end

            success_result(
              JSON.generate(
                {
                  "files" => statuses,
                },
              ),
            )
          rescue PatchFormatError => e
            error_result("apply_patch failed: #{e.message}")
          rescue SecurityError => e
            error_result(e.message)
          end

          def exec(arguments)
            command = arguments.fetch("command", "").to_s.strip
            return error_result("exec requires command") if command.empty?

            stdout, stderr, status =
              Open3.capture3(
                "/bin/sh",
                "-lc",
                command,
                chdir: workspace_root.to_s,
              )

            success_result(
              JSON.generate(
                {
                  "status" => status.success? ? "ok" : "error",
                  "exit_code" => status.exitstatus,
                  "stdout" => normalize_stream_output(stdout),
                  "stderr" => normalize_stream_output(stderr),
                },
              ),
            )
          rescue StandardError => e
            error_result("exec failed: #{e.class}: #{e.message}")
          end

          def normalize_workspace_root(value)
            root = value.to_s.strip
            raise SecurityError, "workspace root is required" if root.empty?

            path = Pathname.new(root).expand_path
            raise SecurityError, "workspace root must exist" unless path.directory?

            path.realpath
          end

          def resolve_existing_path(relative_path)
            expanded = resolve_under_workspace(relative_path)
            real = expanded.realpath
            ensure_within_workspace!(real)
            real
          end

          def resolve_output_path(relative_path)
            expanded = resolve_under_workspace(relative_path)
            parent = nearest_existing_parent(expanded)
            ensure_within_workspace!(parent.realpath)
            expanded
          end

          def resolve_under_workspace(relative_path)
            raise SecurityError, "path must be relative to the workspace root" if relative_path.to_s.start_with?("/", "~")

            expanded = workspace_root.join(relative_path).expand_path
            ensure_within_workspace!(expanded)
            expanded
          end

          def ensure_within_workspace!(path)
            normalized = path.expand_path.to_s
            root = workspace_root.to_s
            return if normalized == root || normalized.start_with?(root + File::SEPARATOR)

            raise SecurityError, "path escapes the workspace root"
          end

          def nearest_existing_parent(path)
            current = path
            current = current.parent until current.exist?
            current
          end

          def codex_patch_format?(patch_text)
            patch_text.lstrip.start_with?(CODEX_PATCH_BEGIN)
          end

          def apply_unified_patch(patch_text)
            normalized_patch_text = normalize_unified_patch_text(patch_text)
            affected_paths = parse_patch_paths(normalized_patch_text)
            raise PatchFormatError, "apply_patch did not include any file paths" if affected_paths.empty?

            affected_files = affected_paths.to_h do |relative_path|
              [relative_path, resolve_under_workspace(relative_path)]
            end

            Dir.mktmpdir("claw-apply-patch-") do |tmpdir|
              prepare_patch_workspace(tmpdir:, affected_files:)
              stdout, stderr, status =
                Open3.capture3(
                  "patch",
                  "-p0",
                  "-d",
                  tmpdir,
                  "--batch",
                  "--forward",
                  "--reject-file=-",
                  stdin_data: normalized_patch_text,
                )
              raise PatchFormatError, (stderr.presence || stdout.presence || "unknown error") unless status.success?

              commit_patch_workspace(tmpdir:, affected_files:)
            end
          end

          def apply_codex_patch(patch_text)
            parse_codex_patch_operations(patch_text).map do |operation|
              case operation.fetch(:type)
              when :add
                path = resolve_output_path(operation.fetch(:path))
                raise PatchFormatError, "apply_patch add target already exists: #{operation.fetch(:path)}" if path.exist?

                FileUtils.mkdir_p(path.dirname)
                File.write(path, operation.fetch(:content), mode: "w", encoding: Encoding::UTF_8)
                { "path" => operation.fetch(:path), "status" => "added" }
              when :delete
                path = resolve_existing_path(operation.fetch(:path))
                File.delete(path)
                { "path" => operation.fetch(:path), "status" => "deleted" }
              when :update
                apply_codex_update(operation)
              else
                raise PatchFormatError, "unsupported apply_patch operation: #{operation.fetch(:type)}"
              end
            end
          end

          def apply_codex_update(operation)
            original_path = resolve_existing_path(operation.fetch(:path))
            content = read_utf8_file(original_path)
            raise PatchFormatError, "apply_patch only supports UTF-8 text files" if content.nil?

            updated = apply_codex_hunks(original_text: content, hunks: operation.fetch(:hunks))
            target_relative_path = operation[:move_to].presence || operation.fetch(:path)
            target_path = resolve_output_path(target_relative_path)
            FileUtils.mkdir_p(target_path.dirname)
            File.write(target_path, updated, mode: "w", encoding: Encoding::UTF_8)
            File.delete(original_path) if target_path != original_path && original_path.exist?

            {
              "path" => target_relative_path,
              "status" => (target_path == original_path ? "modified" : "moved"),
            }
          end

          def apply_codex_hunks(original_text:, hunks:)
            original_lines = original_text.lines(chomp: false)
            result = []
            cursor = 0

            Array(hunks).each do |hunk|
              old_lines = Array(hunk.fetch(:old_lines))
              new_lines = Array(hunk.fetch(:new_lines))
              match_index = find_hunk_match_index(original_lines:, old_lines:, start_index: cursor)
              raise PatchFormatError, "apply_patch hunk did not match the target file" if match_index.nil?

              result.concat(original_lines[cursor...match_index])
              result.concat(new_lines)
              cursor = match_index + old_lines.length
            end

            result.concat(original_lines[cursor..] || [])
            result.join
          end

          def find_hunk_match_index(original_lines:, old_lines:, start_index:)
            return start_index if old_lines.empty?

            limit = original_lines.length - old_lines.length
            return nil if limit.negative?

            start_index.upto(limit) do |candidate|
              candidate_lines = original_lines[candidate, old_lines.length]
              return candidate if patch_line_sequences_match?(candidate_lines, old_lines)
            end

            nil
          end

          def patch_line_sequences_match?(candidate_lines, patch_lines)
            return false unless candidate_lines.length == patch_lines.length

            candidate_lines.zip(patch_lines).all? do |candidate, patch_line|
              patch_line_match?(candidate, patch_line)
            end
          end

          def patch_line_match?(candidate, patch_line)
            candidate == patch_line || candidate.to_s.chomp("\n") == patch_line.to_s.chomp("\n")
          end

          def parse_codex_patch_operations(patch_text)
            lines = patch_text.lines(chomp: false)
            raise PatchFormatError, "apply_patch must start with #{CODEX_PATCH_BEGIN}" unless lines.first.to_s.strip == CODEX_PATCH_BEGIN

            index = 1
            operations = []

            while index < lines.length
              line = lines[index]
              stripped = line.to_s.strip
              break if stripped == CODEX_PATCH_END

              if line.start_with?(CODEX_UPDATE_FILE)
                path = line.delete_prefix(CODEX_UPDATE_FILE).strip
                raise PatchFormatError, "apply_patch update path is required" if path.empty?

                index += 1
                move_to = nil
                if index < lines.length && lines[index].start_with?(CODEX_MOVE_TO)
                  move_to = lines[index].delete_prefix(CODEX_MOVE_TO).strip
                  raise PatchFormatError, "apply_patch move target is required" if move_to.empty?
                  index += 1
                end

                block_lines, index = consume_codex_operation_block(lines, index)
                operations << {
                  type: :update,
                  path: path,
                  move_to: move_to.presence,
                  hunks: parse_codex_hunks(block_lines),
                }
              elsif line.start_with?(CODEX_ADD_FILE)
                path = line.delete_prefix(CODEX_ADD_FILE).strip
                raise PatchFormatError, "apply_patch add path is required" if path.empty?

                index += 1
                block_lines, index = consume_codex_operation_block(lines, index)
                operations << {
                  type: :add,
                  path: path,
                  content: parse_codex_add_lines(block_lines),
                }
              elsif line.start_with?(CODEX_DELETE_FILE)
                path = line.delete_prefix(CODEX_DELETE_FILE).strip
                raise PatchFormatError, "apply_patch delete path is required" if path.empty?

                index += 1
                operations << { type: :delete, path: path }
              else
                raise PatchFormatError, "unsupported apply_patch header: #{stripped}"
              end
            end

            raise PatchFormatError, "apply_patch did not include any file paths" if operations.empty?
            raise PatchFormatError, "apply_patch must end with #{CODEX_PATCH_END}" unless lines.any? { |entry| entry.to_s.strip == CODEX_PATCH_END }

            operations
          end

          def consume_codex_operation_block(lines, index)
            block = []

            while index < lines.length
              line = lines[index]
              stripped = line.to_s.strip
              break if stripped == CODEX_PATCH_END
              break if line.start_with?(CODEX_UPDATE_FILE, CODEX_ADD_FILE, CODEX_DELETE_FILE)

              block << line
              index += 1
            end

            [block, index]
          end

          def parse_codex_add_lines(lines)
            Array(lines).map do |line|
              next "" if line.to_s.strip == CODEX_END_OF_FILE
              raise PatchFormatError, "apply_patch add blocks only support '+' lines" unless line.start_with?("+")

              line.byteslice(1..)
            end.join
          end

          def parse_codex_hunks(lines)
            hunks = []
            current_hunk = nil

            Array(lines).each do |line|
              stripped = line.to_s.strip
              next if stripped == CODEX_END_OF_FILE

              if line.start_with?("@@")
                current_hunk = { old_lines: [], new_lines: [] }
                hunks << current_hunk
                next
              end

              raise PatchFormatError, "apply_patch update blocks require @@ hunks" if current_hunk.nil?

              prefix = line[0]
              content = line.byteslice(1..)

              case prefix
              when " "
                current_hunk[:old_lines] << content
                current_hunk[:new_lines] << content
              when "-"
                current_hunk[:old_lines] << content
              when "+"
                current_hunk[:new_lines] << content
              else
                raise PatchFormatError, "unsupported apply_patch hunk line: #{line.inspect}"
              end
            end

            raise PatchFormatError, "apply_patch update blocks require at least one hunk" if hunks.empty?

            hunks
          end

          def normalize_unified_patch_text(patch_text)
            patch_text.each_line.map do |line|
              if line.start_with?(*PATCH_HEADER_PREFIXES)
                prefix, raw_path = line.split(/\s+/, 2)
                path = raw_path.to_s.split("\t", 2).first.to_s
                normalized_path =
                  if path.start_with?("a/", "b/") && path != "/dev/null"
                    path[2..]
                  else
                    path
                  end

                "#{prefix} #{normalized_path}#{line.end_with?("\n") ? "\n" : ""}"
              else
                line
              end
            end.join
          end

          def parse_patch_paths(patch_text)
            paths = []

            patch_text.each_line do |line|
              next unless line.start_with?(*PATCH_HEADER_PREFIXES)

              raw_path = line.split(/\s+/, 2).last.to_s.split("\t", 2).first.to_s.strip
              next if raw_path.empty? || raw_path == "/dev/null"

              normalized =
                if raw_path.start_with?("a/", "b/")
                  raw_path[2..]
                else
                  raw_path
                end
              next if normalized.to_s.empty?

              paths << normalized
            end

            paths.uniq
          end

          def prepare_patch_workspace(tmpdir:, affected_files:)
            affected_files.each_value do |workspace_path|
              relative_path = workspace_path.relative_path_from(workspace_root).to_s
              tmp_path = Pathname.new(tmpdir).join(relative_path)
              FileUtils.mkdir_p(tmp_path.dirname)
              File.write(tmp_path, workspace_path.binread, mode: "wb") if workspace_path.exist?
            end
          end

          def commit_patch_workspace(tmpdir:, affected_files:)
            affected_files.map do |relative_path, workspace_path|
              tmp_path = Pathname.new(tmpdir).join(relative_path)
              existed_before = workspace_path.exist?

              if tmp_path.exist?
                FileUtils.mkdir_p(workspace_path.dirname)
                File.write(workspace_path, tmp_path.binread, mode: "wb")
                status = existed_before ? "modified" : "added"
              else
                File.delete(workspace_path) if existed_before
                status = "deleted"
              end

              {
                "path" => relative_path,
                "status" => status,
              }
            end
          end

          def file_within_workspace?(relative_path)
            absolute_path = workspace_root.join(relative_path)
            absolute_path.file? && absolute_path.expand_path.to_s.start_with?(workspace_root.to_s + File::SEPARATOR)
          end

          def read_utf8_file(path)
            bytes = path.binread
            text = bytes.dup.force_encoding(Encoding::UTF_8)
            return nil unless text.valid_encoding?

            text
          rescue Errno::ENOENT
            raise
          rescue StandardError
            nil
          end

          def normalize_stream_output(value)
            value.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
          rescue StandardError
            value.to_s
          end

          def success_result(text, metadata: {})
            {
              "content" => [
                {
                  "type" => "text",
                  "text" => text.to_s,
                }
              ],
              "error" => false,
              "metadata" => metadata,
            }
          end

          def error_result(text, metadata: {})
            {
              "content" => [
                {
                  "type" => "text",
                  "text" => text.to_s,
                }
              ],
              "error" => true,
              "metadata" => metadata,
            }
          end
        end
      end
    end
  end
end
