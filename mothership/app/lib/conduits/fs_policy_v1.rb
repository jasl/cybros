module Conduits
  # V1: prefix-based filesystem path evaluation.
  #
  # Semantics (Codex-compatible):
  # - Matching uses starts_with? on normalized paths (no glob)
  # - "workspace:**" is treated as prefix "workspace" for backward compat
  # - Intersection produces the restrictive ceiling of two FS policies
  # - Write implies delete (no separate delete permission)
  module FsPolicyV1
    WORKSPACE_GLOB_SUFFIX = ":**"

    module_function

    # Normalize a path for prefix comparison.
    # - Strips glob suffix (workspace:**  → /workspace)
    # - Ensures leading / (workspace → /workspace)
    # - Resolves .. and . segments (prevents path traversal bypass)
    # - Strips trailing /
    # - Collapses double slashes
    def normalize_path(path)
      p = path.to_s.dup
      p = p.delete_suffix(WORKSPACE_GLOB_SUFFIX) if p.end_with?(WORKSPACE_GLOB_SUFFIX)
      p = "/#{p}" unless p.start_with?("/")
      p = p.gsub(%r{/+}, "/")

      # Resolve . and .. to prevent traversal bypass (e.g. /workspace/../etc/passwd)
      segments = []
      p.split("/").each do |seg|
        case seg
        when ".."
          segments.pop unless segments.empty?
        when ".", ""
          # skip
        else
          segments << seg
        end
      end
      resolved = "/" + segments.join("/")

      resolved = resolved.delete_suffix("/") unless resolved == "/"
      resolved
    end

    # Returns true if +target+ is covered by any prefix in +allowed_prefixes+.
    # Both target and prefixes are normalized before comparison.
    def path_covered?(target, allowed_prefixes)
      return false if allowed_prefixes.nil? || allowed_prefixes.empty?

      norm_target = normalize_path(target)

      allowed_prefixes.any? do |prefix|
        norm_prefix = normalize_path(prefix)
        if norm_prefix == "/"
          true # root prefix covers everything
        else
          norm_target == norm_prefix || norm_target.start_with?("#{norm_prefix}/")
        end
      end
    end

    # Restrictive-ceiling intersection of two FS policy hashes.
    # Each hash has "read" and "write" arrays of path prefixes.
    # Result keeps only paths that are covered by BOTH policies.
    #
    # When one is more specific (sub-path of the other), the more specific wins.
    def intersect(fs_a, fs_b)
      fs_a = { "read" => [], "write" => [] } if fs_a.nil? || fs_a.empty?
      fs_b = { "read" => [], "write" => [] } if fs_b.nil? || fs_b.empty?

      {
        "read" => intersect_paths(Array(fs_a["read"]), Array(fs_b["read"])),
        "write" => intersect_paths(Array(fs_a["write"]), Array(fs_b["write"])),
      }
    end

    # Evaluate whether +requested_fs+ is within the bounds of +policy_fs+.
    # Returns a hash: { allowed:, read:, write:, violations: }
    def evaluate(requested_fs, policy_fs)
      requested_fs ||= { "read" => [], "write" => [] }
      policy_fs ||= { "read" => [], "write" => [] }

      violations = []
      policy_read = Array(policy_fs["read"])
      policy_write = Array(policy_fs["write"])

      Array(requested_fs["read"]).each do |path|
        unless path_covered?(normalize_path(path), policy_read)
          violations << "read path #{path} not covered by policy"
        end
      end

      Array(requested_fs["write"]).each do |path|
        unless path_covered?(normalize_path(path), policy_write)
          violations << "write path #{path} not covered by policy"
        end
      end

      {
        allowed: violations.empty?,
        read: Array(requested_fs["read"]),
        write: Array(requested_fs["write"]),
        violations: violations,
      }
    end

    # --- private helpers ---

    def intersect_paths(paths_a, paths_b)
      return [] if paths_a.empty? || paths_b.empty?

      result = []

      # For each path in A, check if it is covered by any path in B (or vice versa).
      # Keep the more specific (narrower) path.
      paths_a.each do |pa|
        paths_b.each do |pb|
          na = normalize_path(pa)
          nb = normalize_path(pb)

          if na == nb
            result << pa
          elsif na.start_with?("#{nb}/")
            # pa is more specific — covered by pb
            result << pa
          elsif nb.start_with?("#{na}/")
            # pb is more specific — covered by pa
            result << pb
          end
        end
      end

      result.uniq
    end

    private_class_method :intersect_paths
  end
end
