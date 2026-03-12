module Cybros
  module SecondaryDatabaseSchema
    Database = Data.define(:name, :create_task, :load_task, :required_tables)

    DATABASES = {
      queue: Database.new(
        name: :queue,
        create_task: "db:create:queue",
        load_task: "db:schema:load:queue",
        required_tables: %w[
          solid_queue_jobs
          solid_queue_processes
          solid_queue_ready_executions
          solid_queue_scheduled_executions
        ],
      ),
      cable: Database.new(
        name: :cable,
        create_task: "db:create:cable",
        load_task: "db:schema:load:cable",
        required_tables: %w[solid_cable_messages],
      ),
      cache: Database.new(
        name: :cache,
        create_task: "db:create:cache",
        load_task: "db:schema:load:cache",
        required_tables: %w[solid_cache_entries],
      ),
    }.freeze

    module_function

    def database(name)
      DATABASES.fetch(name.to_sym)
    end

    def configured?(name, env_name: Rails.env)
      config = ActiveRecord::Base.configurations.configs_for(env_name: env_name.to_s, name: name.to_s)
      config.present?
    end

    def ready?(name, env_name: Rails.env)
      spec = database(name)
      return false unless configured?(spec.name, env_name: env_name)

      with_connection(spec.name) do |connection|
        spec.required_tables.all? { |table| data_source_exists_fresh?(connection, table) }
      end
    rescue ActiveRecord::AdapterNotSpecified, ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid
      false
    end

    def ensure_configured_schemas!(names: DATABASES.keys)
      Array(names).map(&:to_sym).each do |name|
        next unless configured?(name)

        spec = database(name)
        invoke_task!(spec.create_task)
        next if ready?(name)

        invoke_task!(spec.load_task)

        next if ready?(name)

        raise "#{name} secondary database schema is still not ready after #{spec.load_task}"
      end
    end

    def configured_names(env_name: Rails.env)
      DATABASES.keys.select { |name| configured?(name, env_name: env_name) }
    end

    def with_connection(name)
      klass = connection_class_for(name)
      klass.connection_pool.with_connection do |connection|
        yield connection
      end
    end

    def invoke_task!(task_name)
      task = Rake::Task[task_name]
      task.reenable
      task.invoke
    end

    def data_source_exists_fresh?(connection, table_name)
      connection.select_value("SELECT to_regclass(#{connection.quote(table_name)})::text").present?
    end

    def connection_class_for(name)
      const_name = "#{name.to_s.camelize}Record"
      return const_get(const_name, false) if const_defined?(const_name, false)

      const_set(const_name, Class.new(ActiveRecord::Base)).tap do |klass|
        klass.abstract_class = true
        klass.connects_to database: { writing: name.to_sym }
      end
    end
    private_class_method :connection_class_for, :data_source_exists_fresh?, :invoke_task!
  end
end
