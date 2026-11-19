require 'spec_helper'

# A full reindex builds a fresh versioned collection, marks it `__building`
# while it fills, then points the `products_<code>` alias at it and drops the
# collections it replaced. Driven against the real server.
RSpec.describe Spree::SearchProvider::Typesense, '#reindex' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:provider) { described_class.new(store) }
  let(:layout)   { described_class::IndexLayout.new(typesense_client, 'shop') }
  let(:relation) { double('ActiveRecord::Relation') }

  def product(id) = double("Spree::Product##{id}", id: id)

  def doc_for(id, **extra)
    { 'id' => "prod_#{id}_en_USD", 'product_id' => "prod_#{id}", 'locale' => 'en',
      'currency' => 'USD', 'status' => 'active', 'name' => "Product #{id}",
      'price' => 9.0, 'in_stock' => true, 'store_ids' => ['1'],
      'discontinue_on' => 0, 'units_sold_count' => 0,
      'created_at' => '2024-01-01T00:00:00Z' }.merge(extra.transform_keys(&:to_s))
  end

  def stub_presenter(documents_by_id)
    presenter_class = class_double('SpreeTypesense::ProductPresenter')
    allow(provider).to receive(:presenter_class).and_return(presenter_class)
    allow(presenter_class).to receive(:new) do |p, _store|
      instance_double(SpreeTypesense::ProductPresenter, call: documents_by_id.fetch(p.id) { [doc_for(p.id)] })
    end
  end

  def yield_batches(*batches)
    allow(relation).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
      batches.each { |batch| block.call(batch) }
    end
  end

  def collection_names = typesense_client.collections.retrieve.map { |c| c['name'] }
  def live_ids = ids_in(provider.collection_name)

  def ids_in(name)
    typesense_client.collections[name].documents.search(q: '*', per_page: 100)['hits'].map { |h| h['document']['id'] }
  end

  before do
    reset_typesense_index!('shop')
    reset_typesense_index!('shop_v2')
    allow(relation).to receive(:reorder).with(id: :asc).and_return(relation)
    allow(relation).to receive(:preload_associations_lazily).and_return(relation)
    stub_presenter({})
  end

  after do
    reset_typesense_index!('shop')
    reset_typesense_index!('shop_v2')
  end

  it 'defaults the scope to store.products, batches at 500, and returns the indexed document count' do
    allow(store).to receive(:products).and_return(relation)
    yield_batches([product(1), product(2)])

    expect(provider.reindex).to eq(2)
    expect(live_ids).to contain_exactly('prod_1_en_USD', 'prod_2_en_USD')
  end

  it 'uses the given scope instead of store.products when one is passed' do
    expect(store).not_to receive(:products)
    yield_batches([product(3)])

    expect(provider.reindex(relation)).to eq(1)
  end

  it 'skips a batch that produces no documents' do
    stub_presenter(5 => [])
    yield_batches([product(5)])

    expect(provider).not_to receive(:index_batch)
    expect(provider.reindex(relation)).to eq(0)
  end

  it 'builds a new versioned collection and points the alias at it' do
    yield_batches([product(1)])

    provider.reindex(relation)

    expect(layout.alias_target('products_shop')).to match(layout.version_pattern)
    expect(layout.alias_target('products_shop__building')).to be_nil
    expect(layout.legacy_collection?).to be(false)
  end

  it 'drops the previous versioned collection after the swap' do
    yield_batches([product(1)])
    provider.reindex(relation)
    first = layout.alias_target('products_shop')

    provider.reindex(relation)

    expect(layout.alias_target('products_shop')).not_to eq(first)
    expect(layout.versioned_collections).to eq([layout.alias_target('products_shop')])
  end

  it 'removes the documents of products no longer in the scope' do
    yield_batches([product(1)], [product(2)])
    provider.reindex(relation)

    yield_batches([product(2)])
    provider.reindex(relation)

    expect(live_ids).to eq(['prod_2_en_USD'])
  end

  it 'answers searches from the previous collection until the swap' do
    yield_batches([product(1)])
    provider.reindex(relation)

    seen_mid_run = nil
    allow(relation).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
      block.call([product(2)])
      seen_mid_run = live_ids
      block.call([product(3)])
    end
    provider.reindex(relation)

    expect(seen_mid_run).to eq(['prod_1_en_USD'])
    expect(live_ids).to contain_exactly('prod_2_en_USD', 'prod_3_en_USD')
  end

  it 'replaces a 0.2.0 real collection with the alias' do
    typesense_client.collections.create(described_class::Schema.definition('products_shop'))
    yield_batches([product(1)])

    provider.reindex(relation)

    expect(layout.legacy_collection?).to be(false)
    expect(layout.alias_target('products_shop')).to match(layout.version_pattern)
    expect(live_ids).to eq(['prod_1_en_USD'])
  end

  # A 0.2.0 rollback creates a real collection beside the alias, and it takes
  # requests by that name ahead of the alias; rolling forward must drop it.
  it 'drops a real collection a rollback created beside the alias' do
    yield_batches([product(1)])
    provider.reindex(relation)
    typesense_client.collections.create(described_class::Schema.definition('products_shop'))

    provider.reindex(relation)

    expect(layout.legacy_collection?).to be(false)
    expect(live_ids).to eq(['prod_1_en_USD'])
  end

  # A reindex killed mid-run leaves its marker and collection behind.
  it 'repoints an orphaned __building alias and drops the orphan' do
    orphan = layout.new_version_name(1_700_000_000_000)
    typesense_client.collections.create(described_class::Schema.definition(orphan))
    layout.point!('products_shop__building', orphan)
    yield_batches([product(1)])

    provider.reindex(relation)

    expect(collection_names).not_to include(orphan)
    expect(layout.alias_target('products_shop__building')).to be_nil
  end

  it 'never touches another store whose code extends this one' do
    other = described_class.new(instance_double('Spree::Store', id: 2, code: 'shop_v2'))
    other_layout = described_class::IndexLayout.new(typesense_client, 'shop_v2')
    allow(other).to receive(:presenter_class).and_return(provider.send(:presenter_class))
    yield_batches([product(9)])
    other.reindex(relation)
    other_target = other_layout.alias_target('products_shop_v2')

    yield_batches([product(1)])
    provider.reindex(relation)

    expect(collection_names).to include(other_target)
    expect(other_layout.alias_target('products_shop_v2')).to eq(other_target)
    expect(ids_in('products_shop_v2')).to eq(['prod_9_en_USD'])
  end

  it 'leaves the live alias alone, and drops what it was building, when the reindex raises' do
    yield_batches([product(1)])
    provider.reindex(relation)
    live = layout.alias_target('products_shop')
    allow(relation).to receive(:find_in_batches).and_raise(RuntimeError, 'database went away')

    expect { provider.reindex(relation) }.to raise_error(RuntimeError, 'database went away')
    expect(layout.alias_target('products_shop')).to eq(live)
    expect(layout.alias_target('products_shop__building')).to be_nil
    expect(layout.versioned_collections).to eq([live])
  end

  # A rejected document must neither stop the reindex nor be counted as
  # indexed, and the reindex must end in an error, so `rake
  # spree:search:reindex` fails visibly. The store keeps the index it had.
  describe 'with documents Typesense rejects' do
    let(:logged) { [] }

    before do
      stub_presenter(2 => [doc_for(2, price: 'not a number')])
      logger = Logger.new(File::NULL)
      %i[info warn error].each { |level| allow(logger).to receive(level) { |msg = nil, &blk| logged << (msg || blk&.call) } }
      allow(Rails).to receive(:logger).and_return(logger)
    end

    it 'imports every batch, then raises naming the rejected documents' do
      yield_batches([product(1), product(2)], [product(3)])

      expect { provider.reindex(relation) }.to raise_error(described_class::ImportError, /prod_2_en_USD/) { |e|
        expect(e.failures.map { |f| f[:id] }).to eq(%w[prod_2_en_USD])
      }
      expect(logged.grep(/indexed 1 \(1 total\)/)).not_to be_empty
      expect(logged.grep(/reindex complete: 2 documents indexed, 1 failed/)).not_to be_empty
    end

    it 'leaves the live alias where it was and drops the collection it built' do
      yield_batches([product(1)])
      provider.reindex(relation)
      live = layout.alias_target('products_shop')
      yield_batches([product(1), product(2)])

      expect { provider.reindex(relation) }.to raise_error(described_class::ImportError)
      expect(layout.alias_target('products_shop')).to eq(live)
      expect(layout.alias_target('products_shop__building')).to be_nil
      expect(layout.versioned_collections).to eq([live])
      expect(live_ids).to eq(['prod_1_en_USD'])
    end
  end
end
