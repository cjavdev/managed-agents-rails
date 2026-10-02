require "erb"
require "yaml"

module ManagedAgents
  # One definition file: YAML, or Markdown with YAML frontmatter. Files are
  # rendered through ERB before parsing, like database.yml.
  class Document
    FRONTMATTER = /\A---\s*\n(.*?)\n---\s*(?:\n|\z)(.*)\z/m

    attr_reader :path, :data, :body

    def self.load(path)
      new(path, ERB.new(File.read(path), trim_mode: "-").result)
    rescue Psych::Exception, SyntaxError, NameError => error
      raise DefinitionError, "#{path}: #{error.message}"
    end

    def initialize(path, source)
      @path = Pathname(path)
      @source = source

      if markdown?
        match = source.match(FRONTMATTER)
        raise DefinitionError, "#{path}: expected YAML frontmatter between --- lines" unless match
        @data = parse(match[1])
        @body = match[2].strip.presence
      else
        @data = parse(source)
        @body = nil
      end
    end

    def markdown?
      path.extname == ".md"
    end

    # The rendered file, or the same file with different data (used when the
    # compiled copy handed to `ant apply` needs IDs in place of paths).
    def to_source(data = nil)
      return @source if data.nil?

      yaml = YAML.dump(data.deep_stringify_keys).delete_prefix("---\n")
      markdown? ? "---\n#{yaml}---\n\n#{body}\n" : yaml
    end

    private

    def parse(yaml)
      parsed = YAML.safe_load(yaml, aliases: true, permitted_classes: [Date, Time, Symbol]) || {}
      raise DefinitionError, "#{path}: expected a mapping at the top level" unless parsed.is_a?(Hash)
      parsed.deep_stringify_keys
    end
  end
end
