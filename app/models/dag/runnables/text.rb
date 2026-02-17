module DAG
  module Runnables
    class Text < ApplicationRecord
      self.table_name = "dag_runnables_texts"

      has_one :dag_node,
        as: :runnable,
        class_name: "DAG::Node",
        inverse_of: :runnable
    end
  end
end
