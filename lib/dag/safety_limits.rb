module DAG
  module SafetyLimits
    DEFAULT_MAX_CONTEXT_NODES = 20_000
    DEFAULT_MAX_CONTEXT_EDGES = 40_000
    DEFAULT_MAX_MESSAGE_PAGE_SCANNED_NODES = 2000

    class Exceeded < DAG::Error; end

    def self.max_context_nodes
      env_positive_int("DAG_MAX_CONTEXT_NODES", DEFAULT_MAX_CONTEXT_NODES)
    end

    def self.max_context_edges
      env_positive_int("DAG_MAX_CONTEXT_EDGES", DEFAULT_MAX_CONTEXT_EDGES)
    end

    def self.max_message_page_scanned_nodes
      env_positive_int("DAG_MAX_MESSAGE_PAGE_SCANNED_NODES", DEFAULT_MAX_MESSAGE_PAGE_SCANNED_NODES)
    end

    def self.env_positive_int(key, default)
      value = ENV[key].to_s.strip
      return default if value.blank?

      parsed = Integer(value)
      parsed.positive? ? parsed : default
    rescue ArgumentError, TypeError
      default
    end
    private_class_method :env_positive_int
  end
end
