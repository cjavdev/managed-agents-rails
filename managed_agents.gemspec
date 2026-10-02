require_relative "lib/managed_agents/version"

Gem::Specification.new do |spec|
  spec.name = "managed_agents"
  spec.version = ManagedAgents::VERSION
  spec.authors = ["CJ Avilla"]
  spec.email = ["cjavilla@gmail.com"]
  spec.homepage = "https://github.com/cjavdev/managed-agents-rails"
  spec.summary = "Claude Managed Agents for Rails: agents as files, synced like migrations."
  spec.description = "A Rails engine for Claude Managed Agents. Define agents under app/agents, " \
    "sync them to the Claude API with `ant apply` or the SDK, keep the remote IDs in your " \
    "database, run sessions with custom tools answered by your app, and generate a chat UI."
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md"]
  end

  spec.add_dependency "rails", ">= 7.2"
  spec.add_dependency "anthropic", ">= 1.72"
end
