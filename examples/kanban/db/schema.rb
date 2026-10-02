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

ActiveRecord::Schema[8.1].define(version: 2026_10_01_210437) do
  create_table "boards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "cards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "list_id", null: false
    t.integer "position", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["list_id"], name: "index_cards_on_list_id"
  end

  create_table "lists", force: :cascade do |t|
    t.integer "board_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["board_id"], name: "index_lists_on_board_id"
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
    t.string "remote_id", null: false
    t.string "status", default: "idle", null: false
    t.string "stop_reason"
    t.integer "subject_id"
    t.string "subject_type"
    t.string "title"
    t.datetime "updated_at", null: false
    t.json "usage"
    t.index ["agent_name", "created_at"], name: "index_managed_agents_sessions_on_agent_name_and_created_at"
    t.index ["remote_id"], name: "index_managed_agents_sessions_on_remote_id", unique: true
    t.index ["subject_type", "subject_id"], name: "index_managed_agents_sessions_on_subject"
  end

  add_foreign_key "cards", "lists"
  add_foreign_key "lists", "boards"
  add_foreign_key "managed_agents_events", "managed_agents_sessions", column: "session_id"
end
