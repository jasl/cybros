module Cybros
  module Statistics
    class UsageStats
      EFFECTIVE_TIME_SQL = "COALESCE(dag_nodes.finished_at, dag_nodes.created_at)"

      def self.for_user(user:, since: nil, until_time: nil)
        new(user: user, since: since, until_time: until_time).for_user
      end

      def self.global_by_provider_key(since: nil, until_time: nil)
        new(user: nil, since: since, until_time: until_time).global_by_provider_key
      end

      def initialize(user:, since:, until_time:)
        @user = user
        @since = since
        @until_time = until_time
      end

      def for_user
        {
          "totals" => totals(scope: base_scope),
          "by_model_ref" => by_model_ref(scope: base_scope),
          "by_day" => by_day(scope: base_scope),
        }
      end

      def global_by_provider_key
        by_provider_key(scope: base_scope)
      end

      private

        def base_scope
          scope =
            DAG::Node
              .joins("JOIN dag_graphs ON dag_graphs.id = dag_nodes.graph_id")
              .joins("JOIN conversations ON conversations.id = dag_graphs.attachable_id")
              .where(dag_graphs: { attachable_type: "Conversation" })
              .where(state: DAG::Node::TERMINAL_STATES)
              .where("dag_nodes.metadata ? 'usage'")

          scope = scope.where(conversations: { user_id: @user.id }) if @user
          scope = scope.where("#{EFFECTIVE_TIME_SQL} >= ?", @since) if @since
          scope = scope.where("#{EFFECTIVE_TIME_SQL} <= ?", @until_time) if @until_time
          scope
        end

        def totals(scope:)
          calls, input_tokens, output_tokens =
            scope.pluck(
              Arel.sql("COUNT(*)"),
              Arel.sql(sum_usage_sql("input_tokens")),
              Arel.sql(sum_usage_sql("output_tokens")),
            ).first

          {
            "calls" => calls.to_i,
            "input_tokens" => input_tokens.to_i,
            "output_tokens" => output_tokens.to_i,
            "total_tokens" => input_tokens.to_i + output_tokens.to_i,
          }
        end

        def by_model_ref(scope:)
          provider_key_sql =
            "COALESCE(NULLIF(dag_node_bodies.output->>'provider_key', ''), 'unknown')"
          model_ref_sql =
            "COALESCE(NULLIF(dag_node_bodies.output->>'model_ref', ''), 'unknown')"

          scope
            .joins(:body)
            .group(Arel.sql(provider_key_sql), Arel.sql(model_ref_sql))
            .pluck(
              Arel.sql(provider_key_sql),
              Arel.sql(model_ref_sql),
              Arel.sql("COUNT(*)"),
              Arel.sql(sum_usage_sql("input_tokens")),
              Arel.sql(sum_usage_sql("output_tokens")),
            )
            .map do |provider_key, model_ref, calls, input_tokens, output_tokens|
              {
                "provider_key" => provider_key,
                "model_ref" => model_ref,
                "calls" => calls.to_i,
                "input_tokens" => input_tokens.to_i,
                "output_tokens" => output_tokens.to_i,
                "total_tokens" => input_tokens.to_i + output_tokens.to_i,
              }
            end
            .sort_by { |row| -row.fetch("total_tokens") }
        end

        def by_provider_key(scope:)
          provider_key_sql =
            "COALESCE(NULLIF(dag_node_bodies.output->>'provider_key', ''), 'unknown')"

          scope
            .joins(:body)
            .group(Arel.sql(provider_key_sql))
            .pluck(
              Arel.sql(provider_key_sql),
              Arel.sql("COUNT(*)"),
              Arel.sql(sum_usage_sql("input_tokens")),
              Arel.sql(sum_usage_sql("output_tokens")),
            )
            .map do |provider_key, calls, input_tokens, output_tokens|
              {
                "provider_key" => provider_key,
                "calls" => calls.to_i,
                "input_tokens" => input_tokens.to_i,
                "output_tokens" => output_tokens.to_i,
                "total_tokens" => input_tokens.to_i + output_tokens.to_i,
              }
            end
            .sort_by { |row| -row.fetch("total_tokens") }
        end

        def by_day(scope:)
          day_sql = "DATE(#{EFFECTIVE_TIME_SQL})"

          scope
            .group(Arel.sql(day_sql))
            .order(Arel.sql(day_sql))
            .pluck(
              Arel.sql(day_sql),
              Arel.sql("COUNT(*)"),
              Arel.sql(sum_usage_sql("input_tokens")),
              Arel.sql(sum_usage_sql("output_tokens")),
            )
            .map do |day, calls, input_tokens, output_tokens|
              {
                "date" => day&.to_s,
                "calls" => calls.to_i,
                "input_tokens" => input_tokens.to_i,
                "output_tokens" => output_tokens.to_i,
                "total_tokens" => input_tokens.to_i + output_tokens.to_i,
              }
            end
        end

        def sum_usage_sql(key)
          value_sql = "(dag_nodes.metadata->'usage'->>'#{key}')"
          "SUM(CASE WHEN #{value_sql} ~ '^[0-9]+$' THEN #{value_sql}::bigint ELSE 0 END)"
        end
    end
  end
end
