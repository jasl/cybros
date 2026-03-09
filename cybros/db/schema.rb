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

ActiveRecord::Schema[8.2].define(version: 2026_03_09_000016) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"
  enable_extension "vector"

  create_table "accounts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "settings", default: {}, null: false
    t.datetime "updated_at", null: false
  end

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

  create_table "agent_deployments", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "activated_at"
    t.uuid "agent_program_id", null: false
    t.string "agent_sdk_version"
    t.jsonb "capability_snapshot", default: {}, null: false
    t.string "contract_fingerprint", null: false
    t.datetime "created_at", null: false
    t.datetime "deactivated_at"
    t.string "deployment_bearer_secret_ref", null: false
    t.string "deployment_fingerprint", null: false
    t.string "endpoint_url"
    t.string "health_status", default: "unknown", null: false
    t.jsonb "inspection_details", default: {}, null: false
    t.datetime "last_health_checked_at"
    t.datetime "last_inspected_at"
    t.jsonb "manifest_snapshot", default: {}, null: false
    t.string "protocol_version", null: false
    t.jsonb "schema_snapshot", default: {}, null: false
    t.string "status", default: "inactive", null: false
    t.text "supported_methods", default: [], null: false, array: true
    t.jsonb "transport_config", default: {}, null: false
    t.string "transport_kind", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_program_id"], name: "idx_agent_deploy_active_program", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["agent_program_id"], name: "index_agent_deployments_on_agent_program_id"
    t.index ["id", "agent_program_id"], name: "idx_agent_deployments_id_program", unique: true
  end

  create_table "agent_memory_entries", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.text "content", null: false
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.vector "embedding", limit: 1536, null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id"], name: "index_agent_memory_entries_on_conversation_id"
    t.index ["embedding"], name: "index_agent_memory_entries_on_embedding", opclass: :vector_cosine_ops, using: :hnsw
    t.index ["metadata"], name: "index_agent_memory_entries_on_metadata", using: :gin
  end

  create_table "agent_programs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "active_persona"
    t.jsonb "args", default: {}, null: false
    t.string "config_namespace", null: false
    t.string "config_schema_fingerprint", null: false
    t.jsonb "conversation_config_schema", default: {}, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.jsonb "global_config", default: {}, null: false
    t.jsonb "global_config_schema", default: {}, null: false
    t.string "local_path"
    t.jsonb "manifest_snapshot", default: {}, null: false
    t.string "name", null: false
    t.string "profile_source"
    t.string "published_contract_fingerprint", null: false
    t.datetime "updated_at", null: false
    t.index ["config_namespace"], name: "index_agent_programs_on_config_namespace", unique: true
  end

  create_table "agent_rpc_invocations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_deployment_id", null: false
    t.string "binding_fingerprint", null: false
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.datetime "deployment_activated_at", null: false
    t.jsonb "error_snapshot", default: {}, null: false
    t.string "invocation_id", null: false
    t.uuid "last_session_id"
    t.string "method", null: false
    t.string "request_payload_hash", null: false
    t.jsonb "result_snapshot", default: {}, null: false
    t.string "scope_id", null: false
    t.string "scope_type", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_deployment_id"], name: "index_agent_rpc_invocations_on_agent_deployment_id"
    t.index ["binding_fingerprint", "deployment_activated_at", "scope_type", "scope_id", "method", "invocation_id"], name: "idx_agent_rpc_invocations_replay", unique: true
    t.index ["conversation_id"], name: "index_agent_rpc_invocations_on_conversation_id"
    t.index ["id", "agent_deployment_id"], name: "idx_agent_rpc_invocations_id_deploy", unique: true
  end

  create_table "agent_rpc_operation_receipts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_rpc_invocation_id", null: false
    t.datetime "created_at", null: false
    t.string "method", null: false
    t.string "operation_id", null: false
    t.string "payload_hash", null: false
    t.jsonb "response_snapshot", default: {}, null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_rpc_invocation_id", "operation_id"], name: "idx_agent_rpc_operation_receipts", unique: true
    t.index ["agent_rpc_invocation_id"], name: "index_agent_rpc_operation_receipts_on_agent_rpc_invocation_id"
  end

  create_table "agent_rpc_sessions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_deployment_id", null: false
    t.uuid "agent_program_id", null: false
    t.uuid "agent_rpc_invocation_id"
    t.text "allowed_methods", default: [], null: false, array: true
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.datetime "deployment_activated_at", null: false
    t.string "deployment_fingerprint", null: false
    t.datetime "expires_at", null: false
    t.string "scope_id", null: false
    t.string "scope_type", null: false
    t.string "session_token_digest", null: false
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_deployment_id"], name: "index_agent_rpc_sessions_on_agent_deployment_id"
    t.index ["agent_program_id"], name: "index_agent_rpc_sessions_on_agent_program_id"
    t.index ["agent_rpc_invocation_id", "agent_deployment_id"], name: "idx_agent_rpc_sessions_invocation_deploy"
    t.index ["agent_rpc_invocation_id"], name: "index_agent_rpc_sessions_on_agent_rpc_invocation_id"
    t.index ["conversation_id"], name: "index_agent_rpc_sessions_on_conversation_id"
    t.index ["session_token_digest"], name: "idx_agent_rpc_sessions_token", unique: true
  end

  create_table "automation_runs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "approval_state", default: {}, null: false
    t.uuid "automation_id", null: false
    t.uuid "conversation_run_id"
    t.datetime "created_at", null: false
    t.string "dispatch_key"
    t.datetime "finished_at"
    t.uuid "initiated_by_user_id"
    t.datetime "scheduled_for", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.datetime "started_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.index ["automation_id", "dispatch_key"], name: "idx_automation_runs_dispatch_key", unique: true, where: "(dispatch_key IS NOT NULL)"
    t.index ["automation_id", "scheduled_for"], name: "idx_automation_runs_schedule"
    t.index ["automation_id"], name: "index_automation_runs_on_automation_id"
    t.index ["conversation_run_id"], name: "index_automation_runs_on_conversation_run_id"
    t.index ["initiated_by_user_id"], name: "index_automation_runs_on_initiated_by_user_id"
  end

  create_table "automations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_program_id", null: false
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.uuid "execution_target_id", null: false
    t.string "permission_mode", default: "full_access", null: false
    t.string "schedule_kind"
    t.string "schedule_rrule"
    t.string "schedule_timezone"
    t.string "status", default: "active", null: false
    t.jsonb "task_payload", default: {}, null: false
    t.string "trigger_kind"
    t.jsonb "trigger_payload", default: {}, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agent_program_id"], name: "index_automations_on_agent_program_id"
    t.index ["conversation_id"], name: "index_automations_on_conversation_id"
    t.index ["execution_target_id"], name: "index_automations_on_execution_target_id"
    t.index ["user_id"], name: "index_automations_on_user_id"
  end

  create_table "conversation_kv_entries", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.jsonb "value", default: {}, null: false
    t.uuid "written_by_id"
    t.string "written_by_type"
    t.index ["conversation_id", "key"], name: "index_conversation_kv_entries_on_conversation_id_and_key", unique: true
    t.index ["conversation_id"], name: "index_conversation_kv_entries_on_conversation_id"
    t.index ["written_by_type", "written_by_id"], name: "idx_on_written_by_type_written_by_id_425410460d"
    t.check_constraint "btrim(key::text) <> ''::text", name: "check_conversation_kv_entries_key_present"
  end

  create_table "conversation_runs", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "agent_config_schema_fingerprint"
    t.uuid "agent_deployment_id", null: false
    t.uuid "agent_program_id", null: false
    t.string "contract_fingerprint", null: false
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.uuid "dag_node_id", null: false
    t.jsonb "debug", default: {}, null: false
    t.datetime "deployment_activated_at", null: false
    t.string "deployment_fingerprint", null: false
    t.jsonb "effective_agent_config", default: {}, null: false
    t.string "effective_permission_mode", null: false
    t.jsonb "effective_policy", default: {}, null: false
    t.jsonb "effective_public_settings", default: {}, null: false
    t.jsonb "error", default: {}, null: false
    t.uuid "execution_target_id"
    t.datetime "finished_at"
    t.uuid "initiated_by_user_id"
    t.uuid "provider_credential_id"
    t.datetime "queued_at", null: false
    t.jsonb "runtime_governors", default: {}, null: false
    t.string "selected_model_ref"
    t.jsonb "snapshot", default: {}, null: false
    t.integer "snapshot_version", null: false
    t.datetime "started_at"
    t.string "state", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_deployment_id", "agent_program_id"], name: "idx_conversation_runs_deploy_program"
    t.index ["agent_deployment_id"], name: "index_conversation_runs_on_agent_deployment_id"
    t.index ["agent_program_id"], name: "index_conversation_runs_on_agent_program_id"
    t.index ["conversation_id", "state"], name: "index_conversation_runs_on_conversation_id_and_state"
    t.index ["conversation_id"], name: "index_conversation_runs_on_conversation_id"
    t.index ["dag_node_id"], name: "index_conversation_runs_on_dag_node_id"
    t.index ["execution_target_id"], name: "index_conversation_runs_on_execution_target_id"
    t.index ["initiated_by_user_id"], name: "index_conversation_runs_on_initiated_by_user_id"
    t.index ["provider_credential_id"], name: "index_conversation_runs_on_provider_credential_id"
  end

  create_table "conversations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "agent_config", default: {}, null: false
    t.string "agent_config_schema_fingerprint"
    t.uuid "agent_program_id"
    t.datetime "created_at", null: false
    t.uuid "default_execution_target_id"
    t.uuid "forked_from_node_id"
    t.string "kind", default: "root", null: false
    t.jsonb "metadata", default: {}, null: false
    t.uuid "parent_conversation_id"
    t.string "permission_mode", default: "default", null: false
    t.jsonb "public_settings", default: {}, null: false
    t.uuid "root_conversation_id"
    t.text "summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["agent_program_id"], name: "index_conversations_on_agent_program_id"
    t.index ["default_execution_target_id"], name: "index_conversations_on_default_execution_target_id"
    t.index ["forked_from_node_id"], name: "index_conversations_on_forked_from_node_id"
    t.index ["kind"], name: "index_conversations_on_kind"
    t.index ["parent_conversation_id"], name: "index_conversations_on_parent_conversation_id"
    t.index ["root_conversation_id"], name: "index_conversations_on_root_conversation_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
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
    t.check_constraint "edge_type::text = ANY (ARRAY['sequence'::character varying::text, 'dependency'::character varying::text, 'branch'::character varying::text])", name: "check_dag_edges_edge_type_enum"
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
    t.bigint "next_anchored_seq", default: 0, null: false
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
    t.check_constraint "role::text = ANY (ARRAY['main'::character varying::text, 'branch'::character varying::text])", name: "check_dag_lanes_role_enum"
  end

  create_table "dag_node_bodies", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "input", default: {}, null: false
    t.jsonb "output", default: {}, null: false
    t.jsonb "output_preview", default: {}, null: false
    t.string "type", null: false
    t.datetime "updated_at", null: false
  end

  create_table "dag_node_events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "body_id"
    t.datetime "created_at", null: false
    t.uuid "graph_id", null: false
    t.string "kind", null: false
    t.uuid "node_id", null: false
    t.jsonb "payload", default: {}, null: false
    t.text "text"
    t.uuid "turn_id"
    t.index ["graph_id", "node_id", "id"], name: "index_dag_node_events_graph_node_id_id"
    t.index ["graph_id", "node_id", "kind", "id"], name: "index_dag_node_events_graph_node_kind_id"
    t.index ["graph_id"], name: "index_dag_node_events_on_graph_id"
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
    t.datetime "claim_after_at"
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
    t.index ["graph_id", "lane_id", "node_type", "created_at", "id"], name: "index_dag_nodes_active_lane_type_created", where: "(compressed_at IS NULL)"
    t.index ["graph_id", "lane_id", "turn_id", "node_type", "id"], name: "index_dag_nodes_active_lane_turn_type", where: "(compressed_at IS NULL)"
    t.index ["graph_id", "lane_id"], name: "index_dag_nodes_lane"
    t.index ["graph_id", "lease_expires_at"], name: "index_dag_nodes_running_lease", where: "((compressed_at IS NULL) AND ((state)::text = 'running'::text))"
    t.index ["graph_id", "retry_of_id"], name: "index_dag_nodes_retry_of"
    t.index ["graph_id", "state", "claim_after_at"], name: "index_dag_nodes_claim_after", where: "((compressed_at IS NULL) AND ((state)::text = 'pending'::text))"
    t.index ["graph_id", "state", "node_type"], name: "index_dag_nodes_lookup"
    t.index ["graph_id", "turn_id", "node_type", "idempotency_key"], name: "index_dag_nodes_idempotency", unique: true, where: "((compressed_at IS NULL) AND (idempotency_key IS NOT NULL))"
    t.index ["graph_id", "turn_id"], name: "index_dag_nodes_turn"
    t.index ["graph_id", "version_set_id"], name: "index_dag_nodes_version_set"
    t.index ["graph_id"], name: "index_dag_nodes_on_graph_id"
    t.index ["retry_of_id"], name: "index_dag_nodes_on_retry_of_id"
    t.check_constraint "(compressed_at IS NULL) = (compressed_by_id IS NULL)", name: "check_dag_nodes_compressed_fields_consistent"
    t.check_constraint "context_excluded_at IS NULL OR (state::text = ANY (ARRAY['finished'::character varying::text, 'errored'::character varying::text, 'rejected'::character varying::text, 'skipped'::character varying::text, 'stopped'::character varying::text]))", name: "check_dag_nodes_context_excluded_terminal"
    t.check_constraint "deleted_at IS NULL OR (state::text = ANY (ARRAY['finished'::character varying::text, 'errored'::character varying::text, 'rejected'::character varying::text, 'skipped'::character varying::text, 'stopped'::character varying::text]))", name: "check_dag_nodes_deleted_terminal"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying::text, 'awaiting_approval'::character varying::text, 'running'::character varying::text, 'finished'::character varying::text, 'errored'::character varying::text, 'rejected'::character varying::text, 'skipped'::character varying::text, 'stopped'::character varying::text])", name: "check_dag_nodes_state_enum"
  end

  create_table "dag_turns", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "anchor_created_at"
    t.datetime "anchor_created_at_including_deleted"
    t.uuid "anchor_node_id"
    t.uuid "anchor_node_id_including_deleted"
    t.bigint "anchored_seq"
    t.datetime "created_at", null: false
    t.uuid "graph_id", null: false
    t.uuid "lane_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "next_activity_seq", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["graph_id", "id"], name: "index_dag_turns_graph_visible", where: "(anchor_node_id IS NOT NULL)"
    t.index ["graph_id", "lane_id", "anchored_seq"], name: "index_dag_turns_graph_lane_anchored_seq_unique", unique: true, where: "(anchored_seq IS NOT NULL)"
    t.index ["graph_id", "lane_id", "id"], name: "index_dag_turns_graph_lane_id_unique", unique: true
    t.index ["graph_id", "lane_id", "id"], name: "index_dag_turns_graph_lane_visible", where: "(anchor_node_id IS NOT NULL)"
    t.index ["graph_id", "lane_id"], name: "index_dag_turns_graph_lane"
    t.index ["graph_id", "lane_id"], name: "index_dag_turns_graph_lane_visible_including_deleted", where: "(anchor_node_id_including_deleted IS NOT NULL)"
    t.index ["graph_id"], name: "index_dag_turns_on_graph_id"
    t.check_constraint "(anchor_node_id IS NULL) = (anchor_created_at IS NULL)", name: "check_dag_turns_anchor_fields_consistent"
    t.check_constraint "(anchor_node_id_including_deleted IS NULL) = (anchor_created_at_including_deleted IS NULL)", name: "check_dag_turns_anchor_including_deleted_fields_consistent"
    t.check_constraint "anchored_seq IS NULL OR anchored_seq > 0", name: "check_dag_turns_anchored_seq_positive"
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

  create_table "execution_capacity_leases", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "execution_request_id", null: false
    t.datetime "heartbeat_at", null: false
    t.string "holder_id", null: false
    t.string "holder_type", null: false
    t.datetime "lease_expires_at", null: false
    t.jsonb "recovery_metadata", default: {}, null: false
    t.integer "slots", default: 1, null: false
    t.string "status", default: "active", null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_type", "subject_id", "execution_request_id"], name: "idx_execution_capacity_leases_subject_request", unique: true
    t.index ["subject_type", "subject_id", "status"], name: "idx_execution_capacity_leases_subject_status"
  end

  create_table "execution_locations", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.integer "cpu_limit_millicores"
    t.datetime "created_at", null: false
    t.integer "default_timeout_s", null: false
    t.string "environment", null: false
    t.string "kind", null: false
    t.integer "max_concurrent_tasks", null: false
    t.integer "max_queued_tasks", null: false
    t.integer "memory_limit_mb"
    t.string "name", null: false
    t.string "platform", null: false
    t.string "status", default: "active", null: false
    t.text "tags", default: [], null: false, array: true
    t.string "trust_group", null: false
    t.datetime "updated_at", null: false
  end

  create_table "execution_targets", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.integer "cpu_limit_millicores_override"
    t.datetime "created_at", null: false
    t.integer "default_timeout_s_override"
    t.uuid "execution_location_id", null: false
    t.integer "max_concurrent_tasks_override"
    t.integer "max_queued_tasks_override"
    t.integer "memory_limit_mb_override"
    t.string "name", null: false
    t.boolean "sandboxed", default: false, null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.uuid "workspace_id", null: false
    t.index ["execution_location_id", "workspace_id"], name: "idx_execution_targets_on_location_workspace", unique: true
    t.index ["execution_location_id"], name: "index_execution_targets_on_execution_location_id"
    t.index ["workspace_id", "execution_location_id"], name: "idx_execution_targets_on_workspace_location", unique: true
    t.index ["workspace_id"], name: "index_execution_targets_on_workspace_id"
  end

  create_table "identities", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", limit: 255, null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_identities_on_email", unique: true
  end

  create_table "llm_provider_credentials", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "access_token"
    t.string "account_id"
    t.string "api_key"
    t.jsonb "backoff_policy", default: {"kind" => "exponential", "max_delay_ms" => 30000, "base_delay_ms" => 500}, null: false
    t.integer "burst_limit", default: 8, null: false
    t.datetime "created_at", null: false
    t.string "credential_type", null: false
    t.datetime "expires_at"
    t.integer "max_concurrent_requests", default: 4, null: false
    t.string "provider_key", null: false
    t.string "refresh_token"
    t.integer "requests_per_minute", default: 120, null: false
    t.string "status", default: "active", null: false
    t.integer "tokens_per_minute", default: 240000, null: false
    t.datetime "updated_at", null: false
    t.index ["provider_key", "status"], name: "index_llm_provider_credentials_on_provider_key_and_status"
    t.index ["provider_key"], name: "index_llm_provider_credentials_on_active_provider_key", unique: true, where: "((status)::text = 'active'::text)"
  end

  create_table "provider_budget_reservations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "actual_tokens"
    t.datetime "created_at", null: false
    t.integer "estimated_tokens", default: 0, null: false
    t.uuid "provider_credential_id", null: false
    t.string "provider_request_id", null: false
    t.jsonb "reconciliation_metadata", default: {}, null: false
    t.integer "request_units", default: 1, null: false
    t.datetime "reserved_until", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_credential_id", "provider_request_id"], name: "idx_provider_budget_reservations_request", unique: true
    t.index ["provider_credential_id"], name: "index_provider_budget_reservations_on_provider_credential_id"
  end

  create_table "run_drafts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "agent_deployment_id", null: false
    t.uuid "agent_program_id", null: false
    t.jsonb "approval_state", default: {}, null: false
    t.uuid "automation_id"
    t.string "contract_fingerprint", null: false
    t.uuid "conversation_id"
    t.datetime "created_at", null: false
    t.datetime "deployment_activated_at", null: false
    t.string "deployment_fingerprint", null: false
    t.datetime "expires_at", null: false
    t.uuid "initiated_by_user_id"
    t.uuid "materialized_conversation_run_id"
    t.string "permission_mode", null: false
    t.string "prepare_invocation_id"
    t.jsonb "prepared_plan", default: {}, null: false
    t.uuid "proposed_execution_target_id"
    t.uuid "provider_credential_id"
    t.jsonb "runtime_governors", default: {}, null: false
    t.string "selected_model_ref"
    t.jsonb "staged_agent_config_patch", default: {}, null: false
    t.jsonb "staged_kv_ops", default: [], null: false
    t.jsonb "staged_public_settings_patch", default: {}, null: false
    t.string "status", default: "open", null: false
    t.jsonb "trigger_snapshot", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_deployment_id", "agent_program_id"], name: "idx_run_drafts_deploy_program"
    t.index ["agent_deployment_id"], name: "index_run_drafts_on_agent_deployment_id"
    t.index ["agent_program_id"], name: "index_run_drafts_on_agent_program_id"
    t.index ["automation_id", "status"], name: "idx_run_drafts_automation_status"
    t.index ["conversation_id", "status"], name: "idx_run_drafts_conversation_status"
    t.index ["conversation_id"], name: "index_run_drafts_on_conversation_id"
    t.index ["initiated_by_user_id"], name: "index_run_drafts_on_initiated_by_user_id"
    t.index ["materialized_conversation_run_id"], name: "index_run_drafts_on_materialized_conversation_run_id"
    t.index ["proposed_execution_target_id"], name: "index_run_drafts_on_proposed_execution_target_id"
    t.index ["provider_credential_id"], name: "index_run_drafts_on_provider_credential_id"
    t.check_constraint "num_nonnulls(conversation_id, automation_id) = 1", name: "chk_run_drafts_one_entrypoint"
  end

  create_table "runtime_settings", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.jsonb "alert_thresholds", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "default_worker_concurrency", null: false
    t.jsonb "queue_overrides", default: {}, null: false
    t.string "scope_key", default: "instance", null: false
    t.datetime "updated_at", null: false
    t.index ["scope_key"], name: "index_runtime_settings_on_scope_key", unique: true
  end

  create_table "runtime_waits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.string "ordering_key", null: false
    t.string "owner_id", null: false
    t.string "owner_type", null: false
    t.string "reason_type", null: false
    t.datetime "retry_at", null: false
    t.string "status", default: "parked", null: false
    t.uuid "subject_id", null: false
    t.string "subject_type", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "reason_type", "subject_type", "subject_id"], name: "idx_runtime_waits_owner_reason_subject_parked", unique: true, where: "((status)::text = 'parked'::text)"
    t.index ["reason_type", "subject_type", "subject_id", "status", "ordering_key"], name: "idx_runtime_waits_fifo_lookup"
    t.index ["reason_type", "subject_type", "subject_id", "status", "retry_at"], name: "idx_runtime_waits_ready_lookup"
  end

  create_table "sessions", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "identity_id", null: false
    t.string "ip_address"
    t.datetime "last_seen_at"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["identity_id", "created_at"], name: "index_sessions_on_identity_id_and_created_at"
    t.index ["identity_id"], name: "index_sessions_on_identity_id"
  end

  create_table "statistics_tool_call_facts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.string "arguments_resolution"
    t.uuid "conversation_id", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.date "effective_on"
    t.boolean "entered_execution", default: false, null: false
    t.string "execution_readiness", null: false
    t.string "execution_scope", null: false
    t.string "failure_class"
    t.string "failure_code"
    t.datetime "finished_at"
    t.uuid "graph_id", null: false
    t.boolean "manual_retry", default: false, null: false
    t.string "model_attempt_class", null: false
    t.string "model_ref"
    t.string "name_resolution"
    t.string "provider_key"
    t.string "requested_name"
    t.string "resolved_name"
    t.uuid "retry_of_task_node_id"
    t.boolean "retryable"
    t.uuid "root_conversation_id", null: false
    t.string "sample_origin", null: false
    t.string "source"
    t.datetime "started_at"
    t.uuid "task_node_id", null: false
    t.string "tool_call_id"
    t.string "tool_outcome", null: false
    t.uuid "turn_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["sample_origin", "effective_on"], name: "idx_on_sample_origin_effective_on_225d0d9a0c"
    t.index ["sample_origin", "execution_scope"], name: "idx_on_sample_origin_execution_scope_4e168d667a"
    t.index ["sample_origin", "finished_at"], name: "idx_on_sample_origin_finished_at_f04efb09f2"
    t.index ["sample_origin", "model_ref"], name: "idx_on_sample_origin_model_ref_82ffc5e2b6"
    t.index ["sample_origin", "resolved_name"], name: "idx_on_sample_origin_resolved_name_fb102ebc1f"
    t.index ["sample_origin", "started_at"], name: "idx_on_sample_origin_started_at_e983eab176"
    t.index ["sample_origin", "user_id"], name: "index_statistics_tool_call_facts_on_sample_origin_and_user_id"
    t.index ["task_node_id"], name: "index_statistics_tool_call_facts_on_task_node_id", unique: true
    t.check_constraint "duration_ms IS NULL OR duration_ms >= 0", name: "check_statistics_tool_call_facts_duration_ms_non_negative"
    t.check_constraint "execution_readiness::text = ANY (ARRAY['executable'::character varying::text, 'invalid_args'::character varying::text, 'tool_not_found'::character varying::text, 'policy_denied'::character varying::text, 'awaiting_approval'::character varying::text, 'approval_rejected'::character varying::text])", name: "check_statistics_tool_call_facts_execution_readiness_enum"
    t.check_constraint "execution_scope::text = ANY (ARRAY['parent'::character varying::text, 'subagent_child'::character varying::text])", name: "check_statistics_tool_call_facts_execution_scope_enum"
    t.check_constraint "failure_class IS NULL OR (failure_class::text = ANY (ARRAY['validation_error'::character varying::text, 'implementation_error'::character varying::text, 'remote_api_error'::character varying::text, 'timeout'::character varying::text, 'rate_limit'::character varying::text, 'auth'::character varying::text, 'unknown'::character varying::text]))", name: "check_statistics_tool_call_facts_failure_class_enum"
    t.check_constraint "model_attempt_class::text = ANY (ARRAY['first_pass'::character varying::text, 'repaired_name'::character varying::text, 'repaired_args'::character varying::text, 'repaired_both'::character varying::text])", name: "check_statistics_tool_call_facts_model_attempt_class_enum"
    t.check_constraint "sample_origin::text = ANY (ARRAY['runtime'::character varying::text, 'eval'::character varying::text, 'debug'::character varying::text, 'replay'::character varying::text])", name: "check_statistics_tool_call_facts_sample_origin_enum"
    t.check_constraint "tool_outcome::text = ANY (ARRAY['success'::character varying::text, 'failed'::character varying::text, 'not_executed'::character varying::text])", name: "check_statistics_tool_call_facts_tool_outcome_enum"
  end

  create_table "users", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "identity_id", null: false
    t.string "role", default: "owner", null: false
    t.datetime "updated_at", null: false
    t.index ["identity_id"], name: "index_users_on_identity_id", unique: true
  end

  create_table "workspaces", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.text "capability_tags", default: [], null: false, array: true
    t.datetime "created_at", null: false
    t.uuid "execution_location_id", null: false
    t.string "name", null: false
    t.string "root_path", null: false
    t.string "status", default: "active", null: false
    t.text "tags", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.string "workspace_type", null: false
    t.index ["execution_location_id", "root_path"], name: "index_workspaces_on_execution_location_id_and_root_path", unique: true
    t.index ["execution_location_id"], name: "index_workspaces_on_execution_location_id"
    t.index ["id", "execution_location_id"], name: "index_workspaces_on_id_and_execution_location_id", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_deployments", "agent_programs"
  add_foreign_key "agent_memory_entries", "conversations"
  add_foreign_key "agent_rpc_invocations", "agent_deployments"
  add_foreign_key "agent_rpc_invocations", "agent_rpc_sessions", column: "last_session_id"
  add_foreign_key "agent_rpc_invocations", "conversations"
  add_foreign_key "agent_rpc_operation_receipts", "agent_rpc_invocations"
  add_foreign_key "agent_rpc_sessions", "agent_deployments"
  add_foreign_key "agent_rpc_sessions", "agent_deployments", column: ["agent_deployment_id", "agent_program_id"], primary_key: ["id", "agent_program_id"], name: "fk_agent_rpc_sessions_deploy_program"
  add_foreign_key "agent_rpc_sessions", "agent_programs"
  add_foreign_key "agent_rpc_sessions", "agent_rpc_invocations"
  add_foreign_key "agent_rpc_sessions", "agent_rpc_invocations", column: ["agent_rpc_invocation_id", "agent_deployment_id"], primary_key: ["id", "agent_deployment_id"], name: "fk_agent_rpc_sessions_invocation_deploy"
  add_foreign_key "agent_rpc_sessions", "conversations"
  add_foreign_key "automation_runs", "automations"
  add_foreign_key "automation_runs", "conversation_runs", on_delete: :nullify
  add_foreign_key "automation_runs", "users", column: "initiated_by_user_id"
  add_foreign_key "automations", "agent_programs"
  add_foreign_key "automations", "conversations"
  add_foreign_key "automations", "execution_targets"
  add_foreign_key "automations", "users"
  add_foreign_key "conversation_kv_entries", "conversations"
  add_foreign_key "conversation_runs", "agent_deployments"
  add_foreign_key "conversation_runs", "agent_deployments", column: ["agent_deployment_id", "agent_program_id"], primary_key: ["id", "agent_program_id"], name: "fk_conversation_runs_deploy_program"
  add_foreign_key "conversation_runs", "agent_programs"
  add_foreign_key "conversation_runs", "conversations"
  add_foreign_key "conversation_runs", "execution_targets"
  add_foreign_key "conversation_runs", "llm_provider_credentials", column: "provider_credential_id"
  add_foreign_key "conversation_runs", "users", column: "initiated_by_user_id"
  add_foreign_key "conversations", "agent_programs"
  add_foreign_key "conversations", "conversations", column: "parent_conversation_id", on_delete: :nullify
  add_foreign_key "conversations", "conversations", column: "root_conversation_id", on_delete: :nullify
  add_foreign_key "conversations", "dag_nodes", column: "forked_from_node_id", on_delete: :nullify
  add_foreign_key "conversations", "execution_targets", column: "default_execution_target_id"
  add_foreign_key "conversations", "users"
  add_foreign_key "dag_edges", "dag_graphs", column: "graph_id"
  add_foreign_key "dag_edges", "dag_nodes", column: ["graph_id", "from_node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_edges_from_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_edges", "dag_nodes", column: ["graph_id", "to_node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_edges_to_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_lanes", "dag_graphs", column: "graph_id", on_delete: :cascade
  add_foreign_key "dag_lanes", "dag_lanes", column: "merged_into_lane_id", on_delete: :nullify
  add_foreign_key "dag_lanes", "dag_lanes", column: "parent_lane_id", on_delete: :nullify
  add_foreign_key "dag_lanes", "dag_nodes", column: "forked_from_node_id", on_delete: :nullify
  add_foreign_key "dag_lanes", "dag_nodes", column: "root_node_id", on_delete: :nullify
  add_foreign_key "dag_node_events", "dag_graphs", column: "graph_id", on_delete: :cascade
  add_foreign_key "dag_node_events", "dag_nodes", column: ["graph_id", "node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_node_events_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_node_visibility_patches", "dag_graphs", column: "graph_id", on_delete: :cascade
  add_foreign_key "dag_node_visibility_patches", "dag_nodes", column: ["graph_id", "node_id"], primary_key: ["graph_id", "id"], name: "fk_dag_visibility_patches_node_graph_scoped", on_delete: :cascade
  add_foreign_key "dag_nodes", "dag_graphs", column: "graph_id"
  add_foreign_key "dag_nodes", "dag_lanes", column: ["graph_id", "lane_id"], primary_key: ["graph_id", "id"], name: "fk_dag_nodes_lane_graph_scoped"
  add_foreign_key "dag_nodes", "dag_node_bodies", column: "body_id"
  add_foreign_key "dag_nodes", "dag_nodes", column: ["graph_id", "compressed_by_id"], primary_key: ["graph_id", "id"], name: "fk_dag_nodes_compressed_by_graph_scoped"
  add_foreign_key "dag_nodes", "dag_nodes", column: ["graph_id", "retry_of_id"], primary_key: ["graph_id", "id"], name: "fk_dag_nodes_retry_of_graph_scoped"
  add_foreign_key "dag_nodes", "dag_turns", column: ["graph_id", "lane_id", "turn_id"], primary_key: ["graph_id", "lane_id", "id"], name: "fk_dag_nodes_turn_graph_scoped", deferrable: :deferred
  add_foreign_key "dag_turns", "dag_graphs", column: "graph_id", on_delete: :cascade
  add_foreign_key "dag_turns", "dag_lanes", column: ["graph_id", "lane_id"], primary_key: ["graph_id", "id"], name: "fk_dag_turns_lane_graph_scoped", on_delete: :cascade
  add_foreign_key "events", "conversations"
  add_foreign_key "execution_targets", "execution_locations"
  add_foreign_key "execution_targets", "workspaces"
  add_foreign_key "execution_targets", "workspaces", column: ["workspace_id", "execution_location_id"], primary_key: ["id", "execution_location_id"], name: "fk_execution_targets_workspace_location"
  add_foreign_key "provider_budget_reservations", "llm_provider_credentials", column: "provider_credential_id"
  add_foreign_key "run_drafts", "agent_deployments"
  add_foreign_key "run_drafts", "agent_deployments", column: ["agent_deployment_id", "agent_program_id"], primary_key: ["id", "agent_program_id"], name: "fk_run_drafts_deployment_program"
  add_foreign_key "run_drafts", "agent_programs"
  add_foreign_key "run_drafts", "automations"
  add_foreign_key "run_drafts", "conversation_runs", column: "materialized_conversation_run_id"
  add_foreign_key "run_drafts", "conversations"
  add_foreign_key "run_drafts", "execution_targets", column: "proposed_execution_target_id"
  add_foreign_key "run_drafts", "llm_provider_credentials", column: "provider_credential_id"
  add_foreign_key "run_drafts", "users", column: "initiated_by_user_id"
  add_foreign_key "sessions", "identities"
  add_foreign_key "users", "identities"
  add_foreign_key "workspaces", "execution_locations"
end
