# Every spec that indexes into a store's collection starts from nothing: no
# alias, no versioned collection, no 0.2.0-style real collection. Then, if it
# needs an empty live index, it builds one the way a store does, with a
# reindex of nothing.

# A relation with no products, as #reindex reads one.
class EmptyProductScope
  def unscope(*) = self
  def preload_associations_lazily = self
  def find_in_batches(**) = nil
end

# Drops the aliases and every collection the store `code` owns.
def reset_typesense_index!(code)
  layout = Spree::SearchProvider::Typesense::IndexLayout.new(typesense_client, code)
  [layout.live_name, layout.building_name].each { |name| typesense_client.aliases[name].delete rescue nil }
  typesense_client.collections.retrieve.map { |c| c['name'] }
                  .select { |name| name == layout.live_name || layout.version_pattern.match?(name) }
                  .each { |name| typesense_client.collections[name].delete rescue nil }
end

# An empty live index for the provider's store, built by a reindex.
def bootstrap_index!(provider)
  provider.reindex(EmptyProductScope.new)
end
