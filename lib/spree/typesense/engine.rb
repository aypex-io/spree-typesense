module Spree
  module Typesense
    class Engine < ::Rails::Engine
      engine_name 'spree_typesense'
      config.autoload_paths += %W[#{config.root}/app/models]

      # After initialize, so an application's own
      # `Spree::Dependencies.search_product_presenter = ...` (set in an
      # initializer) is already recorded and wins.
      config.after_initialize do
        Spree::Typesense.register_search_product_presenter!
      end

      # Before core activates the subscribers in its own, later,
      # after_initialize.
      config.after_initialize do
        subscriber = Spree::Typesense::MembershipRemovalSubscriber
        Spree.subscribers << subscriber unless Spree.subscribers.include?(subscriber)
      end
    end
  end
end
