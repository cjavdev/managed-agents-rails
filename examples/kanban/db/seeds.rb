board = Board.find_or_create_by!(name: "Product launch")

if board.cards.none?
  board.list_named("To do").cards.create!([
    {title: "Write the launch announcement", description: "Blog post and changelog entry."},
    {title: "Pricing page copy"},
    {title: "Record the demo video"}
  ])
  board.list_named("Doing").cards.create!(title: "Billing: annual plans", description: "Stripe prices exist; checkout still needs the toggle.")
  board.list_named("Done").cards.create!(title: "Pick the launch date")
end
