class CreateTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :tickets do |t|
      t.string :customer_email, null: false
      t.string :subject, null: false
      t.text :body, null: false
      t.string :status, null: false, default: "open"
      t.string :priority
      t.string :category
      t.string :team
      t.text :summary
      t.text :suggested_reply
      t.timestamps
    end

    create_table :daily_digests do |t|
      t.text :body, null: false
      t.timestamps
    end
  end
end
