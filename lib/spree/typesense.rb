require 'spree_core'
require 'typesense'
require 'concurrent/atomic/atomic_boolean'
require 'spree/typesense/version'
require 'spree/typesense/circuit_breaker'
require 'spree/typesense/engine'

module Spree
  # What the gem adds around its search provider,
  # Spree::SearchProvider::Typesense: the document presenter, the circuit
  # breaker and the engine.
  #
  # Inside `module Spree`, a bare `Typesense` now names this module, so code in
  # the Spree namespace reaches the typesense-ruby client as `::Typesense`.
  module Typesense
    PRESENTER_CLASS_NAME = 'Spree::Typesense::ProductPresenter'.freeze

    module_function

    # Spree 6 core ships no search document presenter
    # (`search_product_presenter: nil`); the indexing provider gem supplies one.
    # Same pattern as spree_meilisearch: register ours unless the application,
    # or another search gem, already named one.
    #
    # Only when Typesense is the selected `Spree.search_provider`, though. There
    # is one presenter setting for every installed search gem, so with
    # spree_meilisearch installed too, registering ours while Meilisearch is the
    # selected provider would make spree_meilisearch (whose engine skips
    # registering once the setting is overridden) index with our documents.
    def register_search_product_presenter!
      return unless typesense_selected?
      return if Spree::Dependencies.overridden?(:search_product_presenter)

      Spree::Dependencies.search_product_presenter = PRESENTER_CLASS_NAME
    end

    def typesense_selected?
      provider = Spree.search_provider.to_s.safe_constantize
      provider.is_a?(Class) && provider <= Spree::SearchProvider::Typesense
    end
  end
end
