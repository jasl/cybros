module DAG
  class UsageStats
    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

    def self.call(graph:, lane_id: nil, since: nil, until_time: nil, include_compressed: false, include_deleted: false)
      new(
        graph: graph,
        lane_id: lane_id,
        since: since,
        until_time: until_time,
        include_compressed: include_compressed,
        include_deleted: include_deleted,
      ).call
    end

    def initialize(graph:, lane_id:, since:, until_time:, include_compressed:, include_deleted:)
      @graph = graph
      @lane_id = normalize_optional_uuid(lane_id)
      @since = normalize_optional_time(since, field: "since", code: "dag.usage_stats.since_must_be_a_time")
      @until_time = normalize_optional_time(until_time, field: "until_time", code: "dag.usage_stats.until_time_must_be_a_time")
      @include_compressed = include_compressed == true
      @include_deleted = include_deleted == true

      if @since && @until_time && @until_time < @since
        ValidationError.raise!(
          "until_time must be >= since",
          code: "dag.usage_stats.until_time_must_be_gte_since",
          details: { since: @since.iso8601, until_time: @until_time.iso8601 },
        )
      end
    end

    def call
      totals = totals_hash

      {
        "scope" => scope_hash,
        "totals" => totals,
        "by_model" => by_model_rows,
        "by_day" => by_day_rows,
      }
    end

    private

      EFFECTIVE_TIME_SQL = "COALESCE(dag_nodes.finished_at, dag_nodes.created_at)"

      def scope_hash
        {
          "graph_id" => @graph.id.to_s,
          "lane_id" => @lane_id,
          "since" => @since&.iso8601,
          "until_time" => @until_time&.iso8601,
          "include_compressed" => @include_compressed,
          "include_deleted" => @include_deleted,
        }.compact
      end

      def base_scope
        scope = DAG::Node.where(graph_id: @graph.id)
        scope = scope.where(lane_id: @lane_id) if @lane_id

        unless @include_compressed
          scope = scope.where(compressed_at: nil)
        end

        unless @include_deleted
          scope = scope.where(deleted_at: nil)
        end

        scope = scope.where(state: DAG::Node::TERMINAL_STATES)
        scope = scope.where("dag_nodes.metadata ? 'usage'")

        if @since
          scope = scope.where("#{EFFECTIVE_TIME_SQL} >= ?", @since)
        end

        if @until_time
          scope = scope.where("#{EFFECTIVE_TIME_SQL} <= ?", @until_time)
        end

        scope
      end

      def totals_hash
        calls, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens =
          base_scope.pluck(
            Arel.sql("COUNT(*)"),
            Arel.sql(sum_usage_sql("input_tokens")),
            Arel.sql(sum_usage_sql("output_tokens")),
            Arel.sql(sum_usage_sql("cache_creation_tokens")),
            Arel.sql(sum_usage_sql("cache_read_tokens")),
          ).first

        usage_hash(
          calls: calls,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          cache_creation_tokens: cache_creation_tokens,
          cache_read_tokens: cache_read_tokens,
        )
      end

      def by_model_rows
        provider_sql = "COALESCE(NULLIF(dag_node_bodies.output->>'provider', ''), 'unknown')"
        model_sql = "COALESCE(NULLIF(dag_node_bodies.output->>'model', ''), 'unknown')"

        base_scope
          .joins(:body)
          .group(Arel.sql(provider_sql), Arel.sql(model_sql))
          .pluck(
            Arel.sql(provider_sql),
            Arel.sql(model_sql),
            Arel.sql("COUNT(*)"),
            Arel.sql(sum_usage_sql("input_tokens")),
            Arel.sql(sum_usage_sql("output_tokens")),
            Arel.sql(sum_usage_sql("cache_creation_tokens")),
            Arel.sql(sum_usage_sql("cache_read_tokens")),
          )
          .map do |provider, model, calls, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens|
            usage_hash(
              provider: provider,
              model: model,
              calls: calls,
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              cache_creation_tokens: cache_creation_tokens,
              cache_read_tokens: cache_read_tokens,
            )
          end
          .sort_by { |row| -row.fetch("total_tokens") }
      end

      def by_day_rows
        day_sql = "DATE(#{EFFECTIVE_TIME_SQL})"

        base_scope
          .group(Arel.sql(day_sql))
          .order(Arel.sql(day_sql))
          .pluck(
            Arel.sql(day_sql),
            Arel.sql("COUNT(*)"),
            Arel.sql(sum_usage_sql("input_tokens")),
            Arel.sql(sum_usage_sql("output_tokens")),
            Arel.sql(sum_usage_sql("cache_creation_tokens")),
            Arel.sql(sum_usage_sql("cache_read_tokens")),
          )
          .map do |day, calls, input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens|
            usage_hash(
              date: day&.to_s,
              calls: calls,
              input_tokens: input_tokens,
              output_tokens: output_tokens,
              cache_creation_tokens: cache_creation_tokens,
              cache_read_tokens: cache_read_tokens,
            )
          end
      end

      def usage_hash(
        calls:,
        input_tokens:,
        output_tokens:,
        cache_creation_tokens:,
        cache_read_tokens:,
        provider: nil,
        model: nil,
        date: nil
      )
        calls = calls.to_i
        input_tokens = input_tokens.to_i
        output_tokens = output_tokens.to_i
        cache_creation_tokens = cache_creation_tokens.to_i
        cache_read_tokens = cache_read_tokens.to_i

        cache_hit_rate =
          if input_tokens.positive?
            cache_read_tokens.to_f / input_tokens
          else
            nil
          end

        out = {
          "calls" => calls,
          "input_tokens" => input_tokens,
          "output_tokens" => output_tokens,
          "cache_creation_tokens" => cache_creation_tokens,
          "cache_read_tokens" => cache_read_tokens,
          "cache_miss_tokens" => [input_tokens - cache_read_tokens, 0].max,
          "total_tokens" => input_tokens + output_tokens,
          "cache_hit_rate" => cache_hit_rate,
        }

        out["date"] = date if date
        out["provider"] = provider if provider
        out["model"] = model if model

        out
      end

      def sum_usage_sql(key)
        value_sql = "(dag_nodes.metadata->'usage'->>'#{key}')"
        "SUM(CASE WHEN #{value_sql} ~ '^[0-9]+$' THEN #{value_sql}::bigint ELSE 0 END)"
      end

      def normalize_optional_uuid(value)
        id = value.to_s.strip
        return nil if id.empty?

        if UUID_RE.match?(id)
          id
        else
          ValidationError.raise!(
            "lane_id must be a UUID",
            code: "dag.usage_stats.lane_id_must_be_a_uuid",
            details: { lane_id: id.byteslice(0, 200).to_s },
          )
        end
      end

      def normalize_optional_time(value, field:, code:)
        return nil if value.nil?

        zone = Time.respond_to?(:zone) ? Time.zone : nil

        time =
          case value
          when Time
            value
          when DateTime
            value.to_time
          when Date
            if zone
              zone.local(value.year, value.month, value.day)
            else
              value.to_time
            end
          when String
            s = value.strip
            return nil if s.empty?

            parse_time_string(s, field: field, code: code, zone: zone)
          else
            ValidationError.raise!(
              "#{field} must be a Time",
              code: code,
              details: { field: field, value_class: value.class.name },
            )
          end

        if time && zone && time.respond_to?(:in_time_zone)
          time = time.in_time_zone(zone)
        end

        time
      end

      def parse_time_string(value, field:, code:, zone:)
        if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          date = Date.iso8601(value)
          if zone
            zone.local(date.year, date.month, date.day)
          else
            date.to_time
          end
        else
          Time.iso8601(value)
        end
      rescue ArgumentError
        ValidationError.raise!(
          "#{field} must be ISO8601 (e.g. 2026-02-24 or 2026-02-24T12:34:56Z)",
          code: code,
          details: { field: field, value_preview: value.byteslice(0, 200).to_s },
        )
      end
  end
end
