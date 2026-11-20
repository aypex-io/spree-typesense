module Spree
  module Typesense
    # Re-indexes a product when it leaves a collection or category whose
    # membership Spree removes without re-indexing it (#20).
    #
    # Deleting a collection or category removes its memberships in a later
    # job (`destroy_async`). Removing one touches the product, but nothing
    # enqueues its index job, so its documents kept the grouping's id and its
    # `pos_<id>` field until it was next saved or the store reindexed. Spree
    # 6.0.4 and later announce each removed membership
    # (`product_collection.deleted`, `product_category.deleted`, naming the
    # product), and this re-indexes the product then, through Spree's own
    # index job. Earlier 6.0 releases announce nothing, and the documents
    # stay as they were until then.
    #
    # Where Spree already re-indexes the product (taking it out of a
    # collection in the admin, say), this enqueues a second, harmless job. A
    # product deleted with its memberships is gone by the time this runs and
    # is left to its own removal.
    class MembershipRemovalSubscriber < Spree::Subscriber
      subscribes_to 'product_collection.deleted', 'product_category.deleted'

      def handle(event)
        return unless Spree::Typesense.typesense_selected?

        Spree::Product.find_by_prefix_id(event.payload['product_id'])&.enqueue_search_index
      end
    end
  end
end
