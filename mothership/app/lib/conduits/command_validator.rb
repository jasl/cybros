module Conduits
  # Two-tier command validation for Trusted / Host profiles.
  #
  # Untrusted profiles delegate enforcement to the sandbox — commands pass
  # through without validation. Trusted/Host profiles run outside (or with
  # limited) sandboxing, so dangerous patterns must be caught at the
  # Mothership level before the directive reaches a territory.
  #
  # Verdicts:
  #   :safe            — command is allowed
  #   :needs_approval  — command contains potentially dangerous patterns
  #   :forbidden       — command is unconditionally blocked
  module CommandValidator
    Result = Data.define(:verdict, :violations)

    # --- Forbidden patterns (unconditionally blocked) ---

    FORBIDDEN_PATTERNS = [
      # Destructive disk-level operations
      { pattern: /\brm\s+(-[a-zA-Z]*r[a-zA-Z]*\s+(-[a-zA-Z]*f[a-zA-Z]*\s+)?|--recursive\b).*\/\s*$/,
        reason: "recursive rm at filesystem root" },
      { pattern: /\brm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+(-[a-zA-Z]*r[a-zA-Z]*\s+)?|--force\b).*\/\s*$/,
        reason: "forced rm at filesystem root" },
      { pattern: /\bmkfs\b/,
        reason: "filesystem format command" },
      { pattern: /\bdd\b.*\bof\s*=\s*\/dev\//,
        reason: "direct device write via dd" },
      # Privilege escalation
      { pattern: /\bsudo\b/,
        reason: "privilege escalation via sudo" },
      { pattern: /\bsu\b\s+-?\s*\w/,
        reason: "privilege escalation via su" },
      { pattern: /\bchmod\s+[0-7]*s/i,
        reason: "setuid/setgid modification" },
      { pattern: /\bchown\s.*root/,
        reason: "ownership change to root" },
      # Fork bombs
      { pattern: /:\(\)\s*\{\s*:\|:\s*&\s*\}\s*;?\s*:/,
        reason: "fork bomb" },
      # Remote code execution pipelines
      { pattern: /\bcurl\b.*\|\s*(ba)?sh\b/,
        reason: "curl-pipe-shell execution" },
      { pattern: /\bwget\b.*\|\s*(ba)?sh\b/,
        reason: "wget-pipe-shell execution" },
    ].freeze

    # --- Patterns requiring approval (potentially dangerous) ---

    APPROVAL_PATTERNS = [
      # Shell metacharacters that enable chaining
      { pattern: /(?<!\\)(?<!\|)\|(?!\|)/,
        reason: "pipe operator" },
      { pattern: /(?<!\\);/,
        reason: "command separator (;)" },
      # Subshell / command substitution
      { pattern: /\$\(/,
        reason: "command substitution $()" },
      { pattern: /`[^`]+`/,
        reason: "backtick command substitution" },
      # Process substitution
      { pattern: /<\(/,
        reason: "process substitution <()" },
      { pattern: />\(/,
        reason: "process substitution >()" },
      # Output redirection (could overwrite files)
      { pattern: /(?<!2)>{1,2}\s*[^&\s]/,
        reason: "output redirection" },
      # Background execution
      { pattern: /(?<!&)&(?!&)\s*$/,
        reason: "background execution (&)" },
    ].freeze

    # Profiles that skip command validation (sandbox enforces)
    SANDBOX_ENFORCED_PROFILES = %w[untrusted].freeze

    module_function

    # Validate a command string for a given sandbox profile.
    #
    # @param command [String] the shell command to validate
    # @param sandbox_profile [String] the sandbox profile (untrusted/trusted/host/darwin-automation)
    # @return [Result] verdict and violations
    def validate(command, sandbox_profile:)
      profile = sandbox_profile.to_s

      # Untrusted profiles defer to sandbox enforcement — skip validation
      if SANDBOX_ENFORCED_PROFILES.include?(profile)
        return Result.new(verdict: :safe, violations: [])
      end

      cmd = command.to_s.strip
      return Result.new(verdict: :forbidden, violations: ["empty command"]) if cmd.empty?

      violations = []

      # Check forbidden patterns first
      FORBIDDEN_PATTERNS.each do |entry|
        if entry[:pattern].match?(cmd)
          violations << entry[:reason]
        end
      end

      unless violations.empty?
        return Result.new(verdict: :forbidden, violations: violations)
      end

      # Check approval patterns
      APPROVAL_PATTERNS.each do |entry|
        if entry[:pattern].match?(cmd)
          violations << entry[:reason]
        end
      end

      verdict = violations.empty? ? :safe : :needs_approval
      Result.new(verdict: verdict, violations: violations)
    end
  end
end
