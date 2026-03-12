require "test_helper"

class Cybros::SecondaryDatabaseSchemaTest < ActiveSupport::TestCase
  test "configured_names reflect environment-specific secondary databases" do
    assert_equal %i[queue cable], Cybros::SecondaryDatabaseSchema.configured_names(env_name: "development")
    assert_equal [], Cybros::SecondaryDatabaseSchema.configured_names(env_name: "test")
    assert_equal %i[queue cable cache], Cybros::SecondaryDatabaseSchema.configured_names(env_name: "production")
  end

  test "database specs advertise the expected readiness tables and tasks" do
    queue = Cybros::SecondaryDatabaseSchema.database(:queue)
    cable = Cybros::SecondaryDatabaseSchema.database(:cable)
    cache = Cybros::SecondaryDatabaseSchema.database(:cache)

    assert_equal "db:create:queue", queue.create_task
    assert_equal "db:schema:load:queue", queue.load_task
    assert_equal %w[solid_queue_jobs solid_queue_processes solid_queue_ready_executions solid_queue_scheduled_executions], queue.required_tables

    assert_equal "db:create:cable", cable.create_task
    assert_equal "db:schema:load:cable", cable.load_task
    assert_equal %w[solid_cable_messages], cable.required_tables

    assert_equal "db:create:cache", cache.create_task
    assert_equal "db:schema:load:cache", cache.load_task
    assert_equal %w[solid_cache_entries], cache.required_tables
  end

  test "secondary schema files define the expected core tables" do
    queue_schema = Rails.root.join("db/queue_schema.rb").read
    cable_schema = Rails.root.join("db/cable_schema.rb").read
    cache_schema = Rails.root.join("db/cache_schema.rb").read

    assert_includes queue_schema, 'create_table "solid_queue_jobs"'
    assert_includes queue_schema, 'create_table "solid_queue_processes"'

    assert_includes cable_schema, 'create_table "solid_cable_messages"'
    assert_includes cable_schema, "index_solid_cable_messages_on_channel_hash"

    assert_includes cache_schema, 'create_table "solid_cache_entries"'
    assert_includes cache_schema, "index_solid_cache_entries_on_key_hash"
  end
end
