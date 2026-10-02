# Sample tickets. They are not triaged here: open one and press "Triage again"
# once the agent is synced.
[
  ["dana@northwind.example", "Charged twice for October", "Hi, my card shows two charges of $49 on Oct 1 for the same subscription. Can you refund one of them?"],
  ["sam@fabrikam.example", "Can't log in after password reset", "I reset my password this morning and now every login attempt says 'invalid session'. I've tried two browsers. We have a launch tomorrow and nobody on my team can get in either."],
  ["lee@contoso.example", "How do I export my data?", "Is there a way to export all our projects to CSV? I couldn't find it in settings."]
].each do |email, subject, body|
  Ticket.find_or_create_by!(customer_email: email, subject: subject) { |ticket| ticket.body = body }
end
