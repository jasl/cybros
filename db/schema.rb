# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_02_18_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"
  enable_extension "vector"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "conversations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "dag_edges", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "compressed_at"
    t.datetime "created_at", null: false
    t.string "edge_type", null: false
    t.uuid "from_node_id", null: false
    t.uuid "graph_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "to_node_id", null: false
    t.datetime "updated_at", null: false
    t.index ["from_node_id"], name: "index_dag_edges_on_from_node_id"
    t.index ["graph_id", "edge_type"], name: "index_dag_edges_active_type", where: "(compressed_at IS NULL)"
    t.index ["graph_id", "from_node_id", "to_node_id", "edge_type"], name: "index_dag_edges_uniqueness", unique: true
    t.index ["graph_id", "from_node_id"], name: "index_dag_edges_active_from", where: "(compressed_at IS NULL)"
    t.index ["graph_id", "to_node_id"], name: "index_dag_edges_active_to", where: "(compressed_at IS NULL)"
    t.index ["graph_id"], name: "index_dag_edges_on_graph_id"
    t.index ["to_node_id"], name: "index_dag_edges_on_to_node_id"
    t.check_constraint "edge_type::text = ANY (ARRAY['sequence'::character varying, 'dependency'::character varying, 'branch'::character varying]::text[])", name: "check_dag_edges_edge_type_enum"
    t.check_constraint "from_node_id <> to_node_id", name: "check_dag_edges_no_self_loop"
  end

  create_table "dag_graphs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "attachable_id"
    t.string "attachable_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attachable_type", "attachable_id"], name: "index_dag_graphs_on_attachable", unique: true
  end

  create_table "dag_lanes", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "archived_at"
    t.uuid "attachable_id"
    t.string "attachable_type"
    t.datetime "created_at", null: false
    t.uuid "forked_from_node_id"
    t.uuid "graph_id", null: false
    t.datetime "merged_at"
    t.uuid "merged_into_lane_id"
    t.jsonb "metadata", default: {}, null: false
    t.uuid "parent_lane_id"
    t.string "role", null: false
    t.uuid "root_node_id"
    t.datetime "updated_at", null: false
    t.index ["attachable_type", "attachable_id"], name: "index_dag_lanes_on_attachable", unique: true
    t.index ["graph_id", "forked_from_node_id"], name: "index_dag_lanes_graph_forked_from"
    t.index ["graph_id", "id"], name: "index_dag_lanes_graph_id_id_unique", unique: true
    t.index ["graph_id", "merged_into_lane_id"], name: "index_dag_lanes_graph_merged_into"
    t.index ["graph_id", "parent_lane_id"], name: "index_dag_lanes_graph_parent"
    t.index ["graph_id", "role"], name: "index_dag_lanes_graph_role"
    t.index ["graph_id"], name: "index_dag_lanes_main_per_graph", unique: true, where: "((role)::text = 'main'::text)"
    t.index ["graph_id"], name: "index_dag_lanes_on_graph_id"
    t.check_constraint "merged_into_lane_id IS NULL OR merged_into_lane_id <> id", name: "check_dag_lanes_no_self_merge"
    t.check_constraint "parent_lane_id IS NULL OR parent_lane_id <> id", name: "check_dag_lanes_no_self_parent"
    t.check_constraint "role::text = ANY (ARRAY['main'::character varying, 'branch'::character varying]::text[])", name: "check_dag_lanes_role_enum"
  end

  create_table "dag_node_bodies", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "input", default: {}, null: false
    t.jsonb "output", default: {}, null: false
    t.jsonb "output_preview", default: {}, null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "dag_node_visibility_patches", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "context_excluded_at"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.uuid "graph_id", null: false
    t.uuid "node_id", null: false
    t.datetime "updated_at", null: false
    t.index ["graph_id", "node_id"], name: "index_dag_visibility_patches_uniqueness", unique: true
    t.index ["graph_id"], name: "index_dag_node_visibility_patches_on_graph_id"
    t.index ["node_id"], name: "index_dag_node_visibility_patches_on_node_id"
  end

  create_table "dag_nodes", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "body_id", null: false
    t.datetime "claimed_at"
    t.string "claimed_by"
    t.datetime "compressed_at"
    t.uuid "compressed_by_id"
    t.datetime "context_excluded_at"
    t.datetime "created_at", null: false
    t.datetime "deleted_at"
    t.datetime "finished_at"
    t.uuid "graph_id", null: false
    t.datetime "heartbeat_at"
    t.string "idempotency_key"
    t.uuid "lane_id", null: false
    t.datetime "lease_expires_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "node_type", null: false
    t.uuid "retry_of_id"
    t.datetime "started_at"
    t.string "state", null: false
    t.uuid "turn_id", default: -> { "uuidv7()" }, null: false
    t.datetime "updated_at", null: false
    t.uuid "version_set_id", default: -> { "uuidv7()" }, null: false
    t.index ["body_id"], name: "index_dag_nodes_on_body_id", unique: true
    t.index ["compressed_by_id"], name: "index_dag_nodes_on_compressed_by_id"
    t.index ["graph_id", "compressed_at"], name: "index_dag_nodes_compressed_at"
    t.index ["graph_id", "created_at"], name: "index_dag_nodes_created_at"
    t.index ["graph_id", "id"], name: "index_dag_nodes_graph_id_id_unique", unique: true
    t.index ["graph_id", "lane_id"], name: "index_dag_nodes_lane"
    t.index ["graph_id", "lease_expires_at"], name: "index_dag_nodes_running_lease", where: "((compressed_at IS NULL) AND ((state)::text = 'running'::text))"
    t.index ["graph_id", "retry_of_id"], name: "index_dag_nodes_retry_of"
    t.index ["graph_id", "state", "node_type"], name: "index_dag_nodes_lookup"
    t.index ["graph_id", "turn_id", "node_type", "idempotency_key"], name: "index_dag_nodes_idempotency", unique: true, where: "((compressed_at IS NULL) AND (idempotency_key IS NOT NULL))"
    t.index ["graph_id", "turn_id"], name: "index_dag_nodes_turn"
    t.index ["graph_id", "version_set_id"], name: "index_dag_nodes_version_set"
    t.index ["graph_id"], name: "index_dag_nodes_on_graph_id"
    t.index ["retry_of_id"], name: "index_dag_nodes_on_retry_of_id"
    t.check_constraint "(compressed_at IS NULL) = (compressed_by_id IS NULL)", name: "check_dag_nodes_compressed_fields_consistent"
    t.check_constraint "context_excluded_at IS NULL OR (state::text = ANY (ARRAY['finished'::character varying, 'errored'::character varying, 'rejected'::character varying, 'skipped'::character varying, 'cancelled'::character varying]::text[]))", name: "check_dag_nodes_context_excluded_terminal"
    t.check_constraint "deleted_at IS NULL OR (state::text = ANY (ARRAY['finished'::character varying, 'errored'::character varying, 'rejected'::character varying, 'skipped'::character varying, 'cancelled'::character varying]::text[]))", name: "check_dag_nodes_deleted_terminal"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'finished'::character varying, 'errored'::character varying, 'rejected'::character varying, 'skipped'::character varying, 'cancelled'::character varying]::text[])", name: "check_dag_nodes_state_enum"
  end

  create_table "events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.jsonb "particulars", default: {}, null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.index ["conversation_id", "created_at"], name: "index_events_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_events_on_conversation_id"
    t.index ["subject_type", "subject_id", "created_at"], name: "index_events_on_subject_and_created_at"
    t.index ["subject_type", "subject_id"], name: "index_events_on_subject"
  end

  create_table "topics", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "role", null: false
    t.text "summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_topics_main_per_conversation", unique: true, where: "((role)::text = 'main'::text)"
    t.index ["conversation_id"], name: "index_topics_on_conversation_id"
    t.check_constraint "role::text = ANY (ARRAY['main'::character varying, 'branch'::character varying]::text[])", name: "check_topics_role_enum"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "dag_edges", "dag_graphs", column: "graph_id"
  add_foreign_key "dag_edges", "dag_nodes", column: ["graph_id", "from_node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_edges_from_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_edges", "dag_nodes", column: ["graph_id", "to_node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_edges_to_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_lanes", "dag_graphs", column: "graph_id", on_delete: :cascade
  add_foreign_key "dag_lanes", "dag_lanes", column: "merged_into_lane_id", on_delete: :nullify
  add_foreign_key "dag_lanes", "dag_lanes", column: "parent_lane_id", on_delete: :nullify
  add_foreign_key "dag_lanes", "dag_nodes", column: "forked_from_node_id", on_delete: :nullify
  add_foreign_key "dag_lanes", "dag_nodes", column: "root_node_id", on_delete: :nullify
  add_foreign_key "dag_node_visibility_patches", "dag_graphs", column: "graph_id", on_delete: :cascade
  add_foreign_key "dag_node_visibility_patches", "dag_nodes", column: ["graph_id", "node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_visibility_patches_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_nodes", "dag_graphs", column: "graph_id"
  add_foreign_key "dag_nodes", "dag_lanes", column: ["graph_id", "lane_id"], primary_key: ["graph_id", "id"], name: "fk_dag_nodes_lane_graph_scoped"
  add_foreign_key "dag_nodes", "dag_node_bodies", column: "body_id"
  add_foreign_key "dag_nodes", "dag_nodes", column: ["graph_id", "compressed_by_id"], primary_key: ["graph_id", "id"], name: "fk_dag_nodes_compressed_by_graph_scoped"
  add_foreign_key "dag_nodes", "dag_nodes", column: ["graph_id", "retry_of_id"], primary_key: ["graph_id", "id"], name: "fk_dag_nodes_retry_of_graph_scoped"
  add_foreign_key "events", "conversations"
  add_foreign_key "topics", "conversations"
end
