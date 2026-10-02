class CreateTickets < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  def change
    create_table :tickets do |t|
      t.string :subject
      t.string :priority
      t.text :summary
      t.timestamps
    end
  end
end
