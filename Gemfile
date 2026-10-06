source "https://rubygems.org"

gemspec

# The dummy app in test/ loads Action Cable and Action View; the gem itself does not need all of Rails.
gem "rails"

gem "puma"
gem "sqlite3"
gem "propshaft"
gem "turbo-rails"

group :development, :test do
  gem "standard", require: false
end

group :test do
  gem "webmock"
end
