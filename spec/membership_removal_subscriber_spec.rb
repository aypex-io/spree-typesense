require 'spec_helper'

# Spree 6 removes a deleted collection's or category's memberships in a later
# job (`destroy_async`), and nothing re-indexes their products: their
# documents keep the grouping's id and position until each is next saved or
# the store is reindexed. Spree 6.0.4 and later announce each removed
# membership, and the gem re-indexes its product then (#20).
RSpec.describe Spree::Typesense::MembershipRemovalSubscriber do
  let(:product) { double('Spree::Product', enqueue_search_index: nil) }
  let(:products) { double('Spree::Product (class)') }

  before do
    stub_const('Spree::Product', products)
    allow(products).to receive(:find_by_prefix_id).and_return(nil)
    allow(products).to receive(:find_by_prefix_id).with('prod_kept').and_return(product)
    allow(Spree::Typesense).to receive(:typesense_selected?).and_return(true)
  end

  def deliver(name, payload) = described_class.new.call(Spree::Event.new(name: name, payload: payload, store_id: 1))

  it 'subscribes to the removal of a collection or category membership' do
    expect(described_class.subscription_patterns)
      .to contain_exactly('product_collection.deleted', 'product_category.deleted')
  end

  it 're-indexes the product that left a collection' do
    deliver('product_collection.deleted', 'product_id' => 'prod_kept', 'collection_id' => 'coll_gone')

    expect(product).to have_received(:enqueue_search_index)
  end

  it 're-indexes the product that left a category' do
    deliver('product_category.deleted', 'product_id' => 'prod_kept', 'category_id' => 'ctg_gone')

    expect(product).to have_received(:enqueue_search_index)
  end

  # A deleted product takes its memberships with it; its own removal job
  # takes it out of the index, and re-indexing it would put it back.
  it 'leaves a product that is gone alone' do
    expect { deliver('product_collection.deleted', 'product_id' => 'prod_deleted') }.not_to raise_error
  end

  it 'does nothing when Typesense is not the search provider' do
    allow(Spree::Typesense).to receive(:typesense_selected?).and_return(false)

    deliver('product_collection.deleted', 'product_id' => 'prod_kept')

    expect(product).not_to have_received(:enqueue_search_index)
  end
end
