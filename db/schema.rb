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

ActiveRecord::Schema[8.2].define(version: 2026_02_17_002534) do
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
    t.check_constraint "from_node_id <> to_node_id", name: "check_dag_edges_no_self_loop"
  end

  create_table "dag_graphs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "attachable_id", null: false
    t.string "attachable_type", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["attachable_type", "attachable_id"], name: "index_dag_graphs_on_attachable", unique: true
  end

  create_table "dag_node_payloads", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "input", default: {}, null: false
    t.jsonb "output", default: {}, null: false
    t.jsonb "output_preview", default: {}, null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "dag_nodes", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "compressed_at"
    t.uuid "compressed_by_id"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.uuid "graph_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "node_type", null: false
    t.uuid "payload_id", null: false
    t.uuid "retry_of_id"
    t.datetime "started_at"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["compressed_by_id"], name: "index_dag_nodes_on_compressed_by_id"
    t.index ["graph_id", "compressed_at"], name: "index_dag_nodes_compressed_at"
    t.index ["graph_id", "created_at"], name: "index_dag_nodes_created_at"
    t.index ["graph_id", "retry_of_id"], name: "index_dag_nodes_retry_of"
    t.index ["graph_id", "state", "node_type"], name: "index_dag_nodes_lookup"
    t.index ["graph_id"], name: "index_dag_nodes_on_graph_id"
    t.index ["payload_id"], name: "index_dag_nodes_on_payload_id", unique: true
    t.index ["retry_of_id"], name: "index_dag_nodes_on_retry_of_id"
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

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "dag_edges", "dag_graphs", column: "graph_id"
  add_foreign_key "dag_edges", "dag_nodes", column: "from_node_id"
  add_foreign_key "dag_edges", "dag_nodes", column: "to_node_id"
  add_foreign_key "dag_nodes", "dag_graphs", column: "graph_id"
  add_foreign_key "dag_nodes", "dag_node_payloads", column: "payload_id"
  add_foreign_key "dag_nodes", "dag_nodes", column: "compressed_by_id"
  add_foreign_key "dag_nodes", "dag_nodes", column: "retry_of_id"
  add_foreign_key "events", "conversations"
end
