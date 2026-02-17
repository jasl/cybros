module Messages
  class UserMessage < ::DAG::NodeBody
    def editable?
      true
    end
  end
end
