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

ActiveRecord::Schema[8.1].define(version: 2026_02_27_190000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "record_id", null: false
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

  create_table "conduits_audit_events", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "actor_id"
    t.uuid "command_id"
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.uuid "directive_id"
    t.string "event_type", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "severity", default: "info", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conduits_audit_events_on_account_id"
    t.index ["actor_id"], name: "index_conduits_audit_events_on_actor_id"
    t.index ["command_id"], name: "index_conduits_audit_events_on_command_id"
    t.index ["created_at"], name: "index_conduits_audit_events_on_created_at"
    t.index ["directive_id", "created_at"], name: "index_conduits_audit_events_on_directive_id_and_created_at"
    t.index ["directive_id"], name: "index_conduits_audit_events_on_directive_id"
    t.index ["event_type", "created_at"], name: "index_conduits_audit_events_on_event_type_and_created_at"
  end

  create_table "conduits_bridge_entities", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.boolean "available", default: true, null: false
    t.jsonb "capabilities", default: [], null: false
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "entity_ref", null: false
    t.string "entity_type", null: false
    t.datetime "last_seen_at"
    t.string "location"
    t.jsonb "state", default: {}, null: false
    t.uuid "territory_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conduits_bridge_entities_on_account_id"
    t.index ["capabilities"], name: "index_conduits_bridge_entities_on_capabilities", using: :gin
    t.index ["entity_type"], name: "index_conduits_bridge_entities_on_entity_type"
    t.index ["territory_id", "entity_ref"], name: "idx_bridge_entities_territory_ref", unique: true
    t.index ["territory_id"], name: "index_conduits_bridge_entities_on_territory_id"
  end

  create_table "conduits_commands", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.jsonb "approval_reasons", default: [], null: false
    t.uuid "approved_by_user_id"
    t.uuid "bridge_entity_id"
    t.string "capability", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "dispatched_at"
    t.string "error_message"
    t.jsonb "params", default: {}, null: false
    t.jsonb "policy_snapshot"
    t.uuid "requested_by_user_id"
    t.jsonb "result", default: {}, null: false
    t.string "result_hash"
    t.string "state", default: "queued", null: false
    t.uuid "territory_id", null: false
    t.integer "timeout_seconds", default: 30, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conduits_commands_on_account_id"
    t.index ["approved_by_user_id"], name: "index_conduits_commands_on_approved_by_user_id"
    t.index ["bridge_entity_id"], name: "index_conduits_commands_on_bridge_entity_id"
    t.index ["requested_by_user_id"], name: "index_conduits_commands_on_requested_by_user_id"
    t.index ["state"], name: "index_conduits_commands_on_state"
    t.index ["territory_id", "state"], name: "idx_commands_territory_state"
    t.index ["territory_id"], name: "index_conduits_commands_on_territory_id"
  end

  create_table "conduits_directives", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.uuid "approved_by_user_id"
    t.jsonb "artifacts_manifest", default: {}, null: false
    t.datetime "cancel_requested_at"
    t.string "command", null: false
    t.datetime "created_at", null: false
    t.string "cwd"
    t.boolean "diff_truncated", default: false, null: false
    t.jsonb "effective_capabilities", default: {}, null: false
    t.jsonb "egress_proxy_policy_snapshot"
    t.jsonb "env_allowlist", default: [], null: false
    t.jsonb "env_refs", default: [], null: false
    t.integer "exit_code"
    t.uuid "facility_id", null: false
    t.datetime "finished_at"
    t.string "finished_status"
    t.datetime "last_heartbeat_at"
    t.datetime "lease_expires_at"
    t.jsonb "limits", default: {}, null: false
    t.string "nexus_version"
    t.jsonb "policy_snapshot"
    t.uuid "requested_by_user_id", null: false
    t.jsonb "requested_capabilities", default: {}, null: false
    t.string "result_hash"
    t.string "runtime_ref"
    t.string "sandbox_profile", default: "untrusted", null: false
    t.string "sandbox_version"
    t.string "shell"
    t.string "snapshot_after"
    t.string "snapshot_before"
    t.string "state", default: "queued", null: false
    t.integer "stderr_bytes", default: 0, null: false
    t.boolean "stderr_truncated", default: false, null: false
    t.integer "stdout_bytes", default: 0, null: false
    t.boolean "stdout_truncated", default: false, null: false
    t.uuid "territory_id"
    t.integer "timeout_seconds", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conduits_directives_on_account_id"
    t.index ["approved_by_user_id"], name: "index_conduits_directives_on_approved_by_user_id"
    t.index ["facility_id"], name: "index_conduits_directives_on_facility_id"
    t.index ["requested_by_user_id"], name: "index_conduits_directives_on_requested_by_user_id"
    t.index ["state", "account_id", "sandbox_profile"], name: "idx_directives_state_account_profile"
    t.index ["state", "lease_expires_at"], name: "idx_directives_state_lease_expires"
    t.index ["territory_id"], name: "index_conduits_directives_on_territory_id"
  end

  create_table "conduits_enrollment_tokens", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id", null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_user_id", null: false
    t.datetime "expires_at", null: false
    t.jsonb "labels", default: {}, null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.datetime "used_at"
    t.index ["account_id"], name: "index_conduits_enrollment_tokens_on_account_id"
    t.index ["created_by_user_id"], name: "index_conduits_enrollment_tokens_on_created_by_user_id"
    t.index ["token_digest"], name: "index_conduits_enrollment_tokens_on_token_digest", unique: true
  end

  create_table "conduits_facilities", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.datetime "created_at", null: false
    t.string "kind", null: false
    t.uuid "locked_by_directive_id"
    t.uuid "owner_id", null: false
    t.string "repo_url"
    t.jsonb "retention_policy", null: false
    t.string "root_handle"
    t.integer "size_bytes", default: 0, null: false
    t.uuid "territory_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conduits_facilities_on_account_id"
    t.index ["locked_by_directive_id"], name: "index_conduits_facilities_on_locked_by_directive_id"
    t.index ["owner_id"], name: "index_conduits_facilities_on_owner_id"
    t.index ["retention_policy"], name: "index_conduits_facilities_on_retention_policy"
    t.index ["territory_id"], name: "index_conduits_facilities_on_territory_id"
  end

  create_table "conduits_log_chunks", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.binary "bytes", null: false
    t.integer "bytesize", null: false
    t.datetime "created_at", null: false
    t.uuid "directive_id", null: false
    t.integer "seq", null: false
    t.string "stream", null: false
    t.boolean "truncated", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at", "id"], name: "index_conduits_log_chunks_on_created_at_and_id"
    t.index ["directive_id", "stream", "seq"], name: "index_conduits_log_chunks_uniqueness", unique: true
    t.index ["directive_id"], name: "index_conduits_log_chunks_on_directive_id"
  end

  create_table "conduits_policies", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.boolean "active", default: true, null: false
    t.jsonb "approval", default: {}, null: false
    t.datetime "created_at", null: false
    t.jsonb "device", default: {}, null: false
    t.jsonb "fs", default: {}, null: false
    t.string "name", null: false
    t.jsonb "net", default: {}, null: false
    t.integer "priority", default: 0, null: false
    t.jsonb "sandbox_profile_rules", default: {}, null: false
    t.uuid "scope_id"
    t.string "scope_type"
    t.jsonb "secrets", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_conduits_policies_on_account_id"
    t.index ["scope_type", "scope_id"], name: "index_conduits_policies_on_scope"
  end

  create_table "conduits_territories", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.jsonb "capabilities", default: [], null: false
    t.jsonb "capacity", default: {}, null: false
    t.string "client_cert_fingerprint"
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "kind", default: "server", null: false
    t.jsonb "labels", default: {}, null: false
    t.datetime "last_heartbeat_at"
    t.string "location"
    t.string "name", null: false
    t.string "nexus_version"
    t.string "platform"
    t.string "push_platform"
    t.string "push_token"
    t.jsonb "runtime_status", default: {}, null: false
    t.string "status", null: false
    t.jsonb "tags", default: [], null: false
    t.datetime "updated_at", null: false
    t.datetime "websocket_connected_at"
    t.index ["account_id"], name: "index_conduits_territories_on_account_id"
    t.index ["capabilities"], name: "index_conduits_territories_on_capabilities", using: :gin
    t.index ["client_cert_fingerprint"], name: "idx_territories_cert_fingerprint", unique: true, where: "(client_cert_fingerprint IS NOT NULL)"
    t.index ["kind"], name: "index_conduits_territories_on_kind"
    t.index ["status"], name: "index_conduits_territories_on_status"
    t.index ["tags"], name: "index_conduits_territories_on_tags", using: :gin
  end

  create_table "users", id: :uuid, default: -> { "uuidv7()" }, force: :cascade do |t|
    t.uuid "account_id"
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_users_on_account_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "conduits_audit_events", "accounts"
  add_foreign_key "conduits_audit_events", "conduits_commands", column: "command_id"
  add_foreign_key "conduits_audit_events", "conduits_directives", column: "directive_id"
  add_foreign_key "conduits_audit_events", "users", column: "actor_id"
  add_foreign_key "conduits_bridge_entities", "accounts"
  add_foreign_key "conduits_bridge_entities", "conduits_territories", column: "territory_id"
  add_foreign_key "conduits_commands", "accounts"
  add_foreign_key "conduits_commands", "conduits_bridge_entities", column: "bridge_entity_id"
  add_foreign_key "conduits_commands", "conduits_territories", column: "territory_id"
  add_foreign_key "conduits_commands", "users", column: "approved_by_user_id"
  add_foreign_key "conduits_commands", "users", column: "requested_by_user_id"
  add_foreign_key "conduits_directives", "accounts"
  add_foreign_key "conduits_directives", "conduits_facilities", column: "facility_id"
  add_foreign_key "conduits_directives", "conduits_territories", column: "territory_id"
  add_foreign_key "conduits_directives", "users", column: "approved_by_user_id"
  add_foreign_key "conduits_directives", "users", column: "requested_by_user_id"
  add_foreign_key "conduits_enrollment_tokens", "accounts"
  add_foreign_key "conduits_enrollment_tokens", "users", column: "created_by_user_id"
  add_foreign_key "conduits_facilities", "accounts"
  add_foreign_key "conduits_facilities", "conduits_territories", column: "territory_id"
  add_foreign_key "conduits_facilities", "users", column: "owner_id"
  add_foreign_key "conduits_log_chunks", "conduits_directives", column: "directive_id"
  add_foreign_key "conduits_policies", "accounts"
  add_foreign_key "conduits_territories", "accounts"
  add_foreign_key "users", "accounts"
end
