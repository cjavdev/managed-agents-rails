class CreateAccountsAndUsers < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :accounts do |t|
      t.string :name
      t.timestamps
    end

    create_table :users do |t|
      t.references :account
      t.string :name
      t.timestamps
    end
  end
end
