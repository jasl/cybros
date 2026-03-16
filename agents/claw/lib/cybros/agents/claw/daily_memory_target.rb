module Cybros
  module Agents
    module Claw
      module DailyMemoryTarget
        module_function

        def call(date: Date.current)
          "memory/#{date.strftime("%Y-%m-%d")}.md"
        end
      end
    end
  end
end
