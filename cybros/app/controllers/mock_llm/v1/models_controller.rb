module MockLLM
  module V1
    class ModelsController < ApplicationController
      def index
        now = Time.current.to_i

        render json: {
          object: "list",
          data: [
            {
              id: "mock-model",
              object: "model",
              created: now,
              owned_by: "mock_llm",
            },
          ],
        }
      end
    end
  end
end
