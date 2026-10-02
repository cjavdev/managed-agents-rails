class CreateManagedAgentsTables < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :managed_agents_resources do |t|
      t.string :agent_name, null: false
      t.string :kind, null: false
      t.string :key, null: false, default: ""
      t.string :path
      t.string :remote_id, null: false
      t.string :remote_version
      t.string :digest
      t.string :backend
      t.json :lock_data
      t.string :workspace_id
      t.datetime :synced_at
      t.timestamps

      t.index [:agent_name, :kind, :key], unique: true
      t.index :remote_id, unique: true
    end

    create_table :managed_agents_sessions do |t|
      t.string :remote_id, null: false
      t.string :agent_name, null: false
      t.integer :agent_version
      t.references :subject, polymorphic: true
      t.string :title
      t.string :status, null: false, default: "idle"
      t.string :stop_reason
      t.string :deployment_key
      t.json :metadata
      t.json :usage
      t.string :lease_token
      t.datetime :lease_expires_at
      t.datetime :archived_at
      t.timestamps

      t.index :remote_id, unique: true
      t.index [:agent_name, :created_at]
    end

    create_table :managed_agents_events do |t|
      t.references :session, null: false, foreign_key: {to_table: :managed_agents_sessions}
      t.string :remote_id, null: false
      t.string :event_type, null: false
      t.json :payload
      t.datetime :processed_at
      t.datetime :created_at, null: false

      t.index :remote_id, unique: true
      t.index [:session_id, :event_type]
    end
  end
end
