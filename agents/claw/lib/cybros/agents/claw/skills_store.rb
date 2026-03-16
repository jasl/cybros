require "base64"
require "find"
require "pathname"
require "yaml"

module Cybros
  module Agents
    module Claw
      class SkillsStore
        SkillMetadata = Data.define(:name, :description, :location, :metadata)
        Skill = Data.define(:meta, :body_markdown, :body_truncated, :files_index)

        ALLOWED_TOP_DIRS = %w[scripts references assets].freeze
        DEFAULT_MAX_BODY_BYTES = 200_000
        DEFAULT_MAX_FILE_BYTES = 200_000

        def initialize(dirs:, strict: true)
          @strict = strict == true
          @dirs =
            Array(dirs).filter_map do |dir|
              normalized = dir.to_s.strip
              normalized.presence && File.expand_path(normalized)
            end.uniq
        end

        def list_skills
          @dirs.each_with_object([]) do |root, metas|
            next unless File.directory?(root)

            Dir.children(root).sort.each do |entry|
              next if entry.start_with?(".")

              skill_dir = File.join(root, entry)
              next unless File.directory?(skill_dir)

              meta = load_metadata(skill_dir, strict: @strict)
              next if meta.nil?

              if metas.any? { |existing| existing.name == meta.name }
                ValidationError.raise!(
                  "Duplicate skill name detected.",
                  code: "claw.skills.duplicate_skill_name",
                  details: { skill_name: meta.name },
                ) if @strict
                next
              end

              metas << meta
            end
          end.sort_by(&:name)
        end

        def load_skill(name:, max_bytes: DEFAULT_MAX_BODY_BYTES)
          meta = find_skill_metadata!(name)
          skill_md_path = skill_markdown_path(meta.location)
          content = File.binread(skill_md_path)
          frontmatter, body_markdown = parse_frontmatter(content, expected_name: meta.name, path: skill_md_path)
          full_body = body_markdown.to_s
          body_markdown = truncate_utf8_bytes(full_body, max_bytes:)
          truncated = body_markdown.bytesize < full_body.bytesize

          Skill.new(
            meta: SkillMetadata.new(
              name: frontmatter.fetch("name"),
              description: frontmatter.fetch("description"),
              location: meta.location,
              metadata: frontmatter.fetch("metadata", {}),
            ),
            body_markdown: body_markdown,
            body_truncated: truncated,
            files_index: files_index_for(meta.location),
          )
        end

        def read_skill_file(name:, rel_path:, max_bytes: DEFAULT_MAX_FILE_BYTES)
          bytes = read_skill_file_bytes(name:, rel_path:, max_bytes:)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          return text if text.valid_encoding?

          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        end

        def read_skill_file_bytes(name:, rel_path:, max_bytes: DEFAULT_MAX_FILE_BYTES)
          meta = find_skill_metadata!(name)
          normalized = normalize_rel_path(rel_path)
          path = safe_join(meta.location, normalized)
          ValidationError.raise!(
            "Skill file not found.",
            code: "claw.skills.skill_file_not_found",
            details: { name: name.to_s, rel_path: normalized },
          ) unless path.file?

          bytes = File.binread(path)
          bytes.byteslice(0, Integer(max_bytes))
        end

        def self.binary_content_block(bytes:, rel_path:)
          media_type = mime_type_for(rel_path)
          block = {
            "source_type" => "base64",
            "media_type" => media_type,
            "data" => Base64.strict_encode64(bytes),
          }

          case media_type
          when /\Aimage\//
            block.merge("type" => "image")
          when /\Aaudio\//
            block.merge("type" => "audio")
          else
            block.merge(
              "type" => "document",
              "filename" => File.basename(rel_path.to_s),
            )
          end
        end

        def self.text_bytes?(bytes)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          text.valid_encoding? && !text.include?("\u0000")
        end

        def self.mime_type_for(path)
          case File.extname(path.to_s).downcase
          when ".md"
            "text/markdown"
          when ".txt"
            "text/plain"
          when ".json"
            "application/json"
          when ".png"
            "image/png"
          when ".jpg", ".jpeg"
            "image/jpeg"
          when ".gif"
            "image/gif"
          when ".svg"
            "image/svg+xml"
          else
            "application/octet-stream"
          end
        end

        private

        def find_skill_metadata!(name)
          list_skills.find { |meta| meta.name == name.to_s } ||
            ValidationError.raise!(
              "Unknown skill.",
              code: "claw.skills.unknown_skill",
              details: { name: name.to_s },
            )
        end

        def load_metadata(skill_dir, strict:)
          skill_md_path = skill_markdown_path(skill_dir)
          return nil unless skill_md_path

          frontmatter, = parse_frontmatter(File.read(skill_md_path), expected_name: File.basename(skill_dir), path: skill_md_path, strict:)
          return nil if frontmatter.nil?

          SkillMetadata.new(
            name: frontmatter.fetch("name"),
            description: frontmatter.fetch("description"),
            location: File.expand_path(skill_dir),
            metadata: frontmatter.fetch("metadata", {}),
          )
        end

        def skill_markdown_path(skill_dir)
          %w[SKILL.md skill.md].map { |filename| Pathname.new(skill_dir).join(filename) }.find(&:file?)
        end

        def parse_frontmatter(content, expected_name:, path:, strict: true)
          lines = content.to_s.lines
          return invalid_frontmatter("frontmatter must start with ---", strict:) unless lines.first&.strip == "---"

          closing_index = nil
          lines.each_with_index do |line, index|
            next unless index.positive?
            next unless line.strip == "---"

            closing_index = index
            break
          end
          return invalid_frontmatter("frontmatter is missing closing --- delimiter", strict:) if closing_index.nil?

          frontmatter_yaml = lines[1...closing_index].join
          body_string = lines[(closing_index + 1)..].to_a.join
          parsed = YAML.safe_load(frontmatter_yaml, permitted_classes: [], permitted_symbols: [], aliases: false)
          parsed = {} if parsed.nil?
          unless parsed.is_a?(Hash)
            return invalid_frontmatter("frontmatter must be a YAML mapping", strict:)
          end

          frontmatter = Manifest.deep_stringify(parsed)
          name = frontmatter["name"].to_s.strip
          description = frontmatter["description"].to_s.strip
          metadata = frontmatter["metadata"].is_a?(Hash) ? Manifest.deep_stringify(frontmatter["metadata"]) : {}

          if name.empty? || description.empty?
            return invalid_frontmatter("frontmatter.name and frontmatter.description are required", strict:)
          end

          if expected_name.present? && expected_name.to_s != name
            return invalid_frontmatter("skill name must match directory name", strict:)
          end

          [frontmatter.merge("metadata" => metadata), body_string]
        rescue Psych::Exception => e
          invalid_frontmatter("invalid YAML frontmatter: #{e.message}", strict:)
        end

        def invalid_frontmatter(message, strict:)
          ValidationError.raise!(
            message,
            code: "claw.skills.invalid_frontmatter",
            details: { message: message },
          ) if strict

          [nil, ""]
        end

        def files_index_for(skill_dir)
          index = { "scripts" => [], "references" => [], "assets" => [] }
          Find.find(skill_dir.to_s) do |path|
            next unless File.file?(path)

            relative = Pathname.new(path).relative_path_from(Pathname.new(skill_dir)).to_s.tr(File::SEPARATOR, "/")
            top_dir = relative.split("/").first
            next unless index.key?(top_dir)

            index[top_dir] << relative
          end
          index.transform_values(&:sort)
        end

        def normalize_rel_path(value)
          normalized = value.to_s.tr("\\", "/").sub(%r{\A/+}, "")
          top_dir = normalized.split("/").first
          ValidationError.raise!(
            "Skill file path is invalid.",
            code: "claw.skills.invalid_rel_path",
            details: { rel_path: normalized },
          ) if normalized.empty? || normalized.include?("..") || !ALLOWED_TOP_DIRS.include?(top_dir)

          normalized
        end

        def safe_join(root, rel_path)
          candidate = Pathname.new(root).join(rel_path).expand_path
          base = Pathname.new(root).expand_path
          return candidate if candidate.to_s.start_with?(base.to_s + File::SEPARATOR)

          ValidationError.raise!(
            "Skill file path escapes the skill root.",
            code: "claw.skills.rel_path_escapes_skill_root",
            details: { rel_path: rel_path },
          )
        end

        def truncate_utf8_bytes(text, max_bytes:)
          value = text.to_s
          return value if value.bytesize <= max_bytes

          truncated = value.byteslice(0, max_bytes).to_s
          truncated = truncated.byteslice(0, truncated.bytesize - 1).to_s until truncated.valid_encoding? || truncated.empty?
          truncated
        end
      end
    end
  end
end
