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

ActiveRecord::Schema[8.2].define(version: 2026_02_16_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "conversations", id: { type: :string, limit: 25 }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "title"
    t.datetime "updated_at", null: false
  end

  create_table "dag_edges", id: { type: :string, limit: 25 }, force: :cascade do |t|
    t.datetime "compressed_at"
    t.string "conversation_id", limit: 25, null: false
    t.datetime "created_at", null: false
    t.string "edge_type", null: false
    t.string "from_node_id", limit: 25, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "to_node_id", limit: 25, null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "edge_type"], name: "index_dag_edges_active_type", where: "(compressed_at IS NULL)"
    t.index ["conversation_id", "from_node_id", "to_node_id", "edge_type"], name: "index_dag_edges_uniqueness", unique: true
    t.index ["conversation_id", "from_node_id"], name: "index_dag_edges_active_from", where: "(compressed_at IS NULL)"
    t.index ["conversation_id", "to_node_id"], name: "index_dag_edges_active_to", where: "(compressed_at IS NULL)"
    t.check_constraint "edge_type::text = ANY (ARRAY['sequence'::character varying, 'dependency'::character varying, 'branch'::character varying]::text[])", name: "check_dag_edges_edge_type"
    t.check_constraint "from_node_id::text <> to_node_id::text", name: "check_dag_edges_no_self_loop"
  end

  create_table "dag_nodes", id: { type: :string, limit: 25 }, force: :cascade do |t|
    t.datetime "compressed_at"
    t.string "compressed_by_id", limit: 25
    t.text "content"
    t.string "conversation_id", limit: 25, null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "node_type", null: false
    t.string "retry_of_id", limit: 25
    t.datetime "started_at"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "compressed_at"], name: "index_dag_nodes_compressed_at"
    t.index ["conversation_id", "created_at"], name: "index_dag_nodes_created_at"
    t.index ["conversation_id", "retry_of_id"], name: "index_dag_nodes_retry_of"
    t.index ["conversation_id", "state", "node_type"], name: "index_dag_nodes_lookup"
    t.check_constraint "node_type::text = ANY (ARRAY['user_message'::character varying, 'agent_message'::character varying, 'task'::character varying, 'summary'::character varying]::text[])", name: "check_dag_nodes_node_type"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'running'::character varying, 'finished'::character varying, 'errored'::character varying, 'rejected'::character varying, 'skipped'::character varying, 'cancelled'::character varying]::text[])", name: "check_dag_nodes_state"
  end

  create_table "events", id: { type: :string, limit: 25 }, force: :cascade do |t|
    t.string "conversation_id", limit: 25, null: false
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.jsonb "particulars", default: {}, null: false
    t.string "subject_id", limit: 25
    t.string "subject_type"
    t.index ["conversation_id", "created_at"], name: "index_events_on_conversation_id_and_created_at"
    t.index ["subject_type", "subject_id", "created_at"], name: "index_events_on_subject_and_created_at"
  end

  add_foreign_key "dag_edges", "conversations"
  add_foreign_key "dag_edges", "dag_nodes", column: "from_node_id"
  add_foreign_key "dag_edges", "dag_nodes", column: "to_node_id"
  add_foreign_key "dag_nodes", "conversations"
  add_foreign_key "events", "conversations"
end
