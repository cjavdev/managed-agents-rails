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

ActiveRecord::Schema[8.1].define(version: 2026_10_01_210857) do
  create_table "daily_digests", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "managed_agents_connections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "details"
    t.string "display_name"
    t.string "key", null: false
    t.string "kind", null: false
    t.string "remote_id", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.integer "vault_id", null: false
    t.index ["remote_id"], name: "index_managed_agents_connections_on_remote_id", unique: true
    t.index ["vault_id", "key"], name: "index_managed_agents_connections_on_vault_id_and_key", unique: true
    t.index ["vault_id"], name: "index_managed_agents_connections_on_vault_id"
  end

  create_table "managed_agents_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_type", null: false
    t.json "payload"
    t.datetime "processed_at"
    t.string "remote_id", null: false
    t.integer "session_id", null: false
    t.index ["remote_id"], name: "index_managed_agents_events_on_remote_id", unique: true
    t.index ["session_id", "event_type"], name: "index_managed_agents_events_on_session_id_and_event_type"
    t.index ["session_id"], name: "index_managed_agents_events_on_session_id"
  end

  create_table "managed_agents_oauth_clients", force: :cascade do |t|
    t.string "client_id", null: false
    t.text "client_secret"
    t.datetime "created_at", null: false
    t.json "metadata"
    t.string "redirect_uri", null: false
    t.string "server_url", null: false
    t.datetime "updated_at", null: false
    t.index ["server_url", "redirect_uri"], name: "idx_on_server_url_redirect_uri_eb73d89e70", unique: true
  end

  create_table "managed_agents_resources", force: :cascade do |t|
    t.string "agent_name", null: false
    t.string "backend"
    t.datetime "created_at", null: false
    t.string "digest"
    t.string "key", default: "", null: false
    t.string "kind", null: false
    t.json "lock_data"
    t.string "path"
    t.string "remote_id", null: false
    t.string "remote_version"
    t.datetime "synced_at"
    t.datetime "updated_at", null: false
    t.string "workspace_id"
    t.index ["agent_name", "kind", "key"], name: "index_managed_agents_resources_on_agent_name_and_kind_and_key", unique: true
    t.index ["remote_id"], name: "index_managed_agents_resources_on_remote_id", unique: true
  end

  create_table "managed_agents_sessions", force: :cascade do |t|
    t.string "agent_name", null: false
    t.integer "agent_version"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.string "deployment_key"
    t.datetime "lease_expires_at"
    t.string "lease_token"
    t.json "metadata"
    t.integer "owner_id"
    t.string "owner_type"
    t.string "remote_id", null: false
    t.string "status", default: "idle", null: false
    t.string "stop_reason"
    t.integer "subject_id"
    t.string "subject_type"
    t.string "title"
    t.datetime "updated_at", null: false
    t.json "usage"
    t.json "vault_ids"
    t.index ["agent_name", "created_at"], name: "index_managed_agents_sessions_on_agent_name_and_created_at"
    t.index ["owner_type", "owner_id"], name: "index_managed_agents_sessions_on_owner"
    t.index ["remote_id"], name: "index_managed_agents_sessions_on_remote_id", unique: true
    t.index ["subject_type", "subject_id"], name: "index_managed_agents_sessions_on_subject"
  end

  create_table "managed_agents_vaults", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", default: "default", null: false
    t.integer "owner_id", null: false
    t.string "owner_type", null: false
    t.string "remote_id", null: false
    t.datetime "updated_at", null: false
    t.string "workspace_id"
    t.index ["owner_type", "owner_id", "name"], name: "idx_on_owner_type_owner_id_name_06a0d4d67b", unique: true
    t.index ["remote_id"], name: "index_managed_agents_vaults_on_remote_id", unique: true
  end

  create_table "tickets", force: :cascade do |t|
    t.text "body", null: false
    t.string "category"
    t.datetime "created_at", null: false
    t.string "customer_email", null: false
    t.string "priority"
    t.string "status", default: "open", null: false
    t.string "subject", null: false
    t.text "suggested_reply"
    t.text "summary"
    t.string "team"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "managed_agents_connections", "managed_agents_vaults", column: "vault_id"
  add_foreign_key "managed_agents_events", "managed_agents_sessions", column: "session_id"
end
