module ManagedAgents
  # Turns what a session was asked to run with into an ordered list of vaults.
  #
  #   vaults: [current_user, current_user.account, :agent]
  #
  # Order matters: when two vaults hold a credential for the same MCP server,
  # the first one wins. Each entry can be
  #
  #   :agent          the vault from the agent's vault.yaml
  #   :owner          the session owner's vault
  #   another symbol  a method on the owner, e.g. :account for owner.account
  #   a record        that record's default vault (see `has_agent_vault`)
  #   a Vault         a ManagedAgents::Vault, e.g. account.agent_vault!(:billing)
  #   a string        a vault ID
  #
  # A record that has not connected anything has no vault and is skipped.
  class VaultChain
    Link = Struct.new(:source, :remote_id, :covered)

    attr_reader :links

    def initialize(sources, agent:, owner: nil)
      @agent = agent
      @owner = owner
      @links = Array(sources).filter_map { |source| link(source) }.uniq(&:remote_id)
    end

    def remote_ids = links.map(&:remote_id)

    # True when some vault in the chain holds a credential for this URL.
    def covers?(url)
      key = MCP.normalize(url)
      links.any? { |link| link.covered.include?(key) }
    end

    private

    def link(source)
      case source
      when :agent then agent_link
      when :owner then record_link(owner!(source))
      when Symbol then record_link(owner!(source).public_send(source))
      when String then Link.new(source, source, [])
      when Vault then vault_link(source)
      else record_link(source)
      end
    end

    def agent_link
      name = @agent.definition.name
      vault = Resource.lookup(name, "vault") or return
      Link.new(:agent, vault.remote_id, Resource.for_agent(name).of_kind("credential").pluck(:key).map { |key| MCP.normalize(key) })
    end

    def record_link(record)
      return if record.nil?

      vault = Vault.find_by(owner: record, name: Vault::DEFAULT)
      vault && vault_link(vault)
    end

    def vault_link(vault)
      Link.new(vault.owner, vault.remote_id, vault.connections.usable.pluck(:key))
    end

    def owner!(source)
      @owner || raise(ArgumentError, "vaults: [#{source.inspect}] needs an owner: to resolve against")
    end
  end
end
