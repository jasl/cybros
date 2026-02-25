module Messages
  class CharacterMessage < AgentMessage
    class << self
      def default_leaf_repair?
        false
      end
    end
  end
end
