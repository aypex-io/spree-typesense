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
    presenter_class = class_double('Spree::Typesense::ProductPresenter')
    allow(provider).to receive(:presenter_class).and_return(presenter_class)
    allow(presenter_class).to receive(:new) do |p, _store|
      instance_double(Spree::Typesense::ProductPresenter, call: documents_by_id.fetch(p.id) { [doc_for(p.id)] })
    end
  end

  def yield_batches(*batches)
    allow(relation).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
      batches.each { |batch| block.call(batch) }
    end
  end

  # A relation with no order, yielding these batches, as #reindex reads one.
  def relation_yielding(*batches)
    scope = double('ActiveRecord::Relation')
    allow(scope).to receive(:unscope).with(:order).and_return(scope)
    allow(scope).to receive(:preload_associations_lazily).and_return(scope)
    allow(scope).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
      batches.each { |batch| block.call(batch) }
    end
    scope
  end

  def collection_names = typesense_client.collections.retrieve.map { |c| c['name'] }
  def live_ids = ids_in(provider.collection_name)
  def live_names = names_in(provider.collection_name)

  def ids_in(name)
    typesense_client.collections[name].documents.search(q: '*', per_page: 100)['hits'].map { |h| h['document']['id'] }
  end

  def names_in(name)
    typesense_client.collections[name].documents.search(q: '*', per_page: 100)['hits']
                    .to_h { |h| [h['document']['id'], h['document']['name']] }
  end

  def now_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

  before do
    reset_typesense_index!('shop')
    reset_typesense_index!('shop_v2')
    allow(relation).to receive(:unscope).with(:order).and_return(relation)
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

  # find_in_batches walks by primary key and ignores a scoped order: Rails
  # warns "Scoped order is ignored", or under error_on_ignored_order raises
  # before reading a row (#21). The ordered double does what Rails does then.
  it 'hands find_in_batches the scope without its order' do
    ordered = double('ActiveRecord::Relation (ordered)')
    allow(ordered).to receive(:reorder).and_return(ordered)
    allow(ordered).to receive(:unscope).with(:order).and_return(relation)
    allow(ordered).to receive(:preload_associations_lazily).and_return(ordered)
    allow(ordered).to receive(:find_in_batches)
      .and_raise(ArgumentError, 'Scoped order is ignored, use :cursor with :order to configure custom order.')
    yield_batches([product(1)])

    expect(provider.reindex(ordered)).to eq(1)
    expect(live_ids).to eq(['prod_1_en_USD'])
  end

  # So each category's ancestors are read once per batch, not per product
  # (#24).
  it "builds each batch's documents sharing the category ancestors they read" do
    sharing = []
    allow(Spree::Typesense::ProductPresenter).to receive(:sharing_category_ancestors) do |&block|
      sharing << :start
      block.call.tap { sharing << :end }
    end
    allow(provider.send(:presenter_class)).to receive(:new) do |p, _store|
      sharing << p.id
      instance_double(Spree::Typesense::ProductPresenter, call: [doc_for(p.id)])
    end
    yield_batches([product(1), product(2)], [product(3)])

    provider.reindex(relation)

    expect(sharing).to eq([:start, 1, 2, :end, :start, 3, :end])
  end

  # The README invites subclassing the presenter, and a subclass may define
  # its own initialize without the cache.
  it 'reindexes with a presenter subclass whose initialize takes only the product and store' do
    subclass = Class.new(Spree::Typesense::ProductPresenter) do
      def initialize(product, store) = super

      def call = [{ 'id' => "prod_#{product.id}_en_USD", 'product_id' => "prod_#{product.id}", 'locale' => 'en',
                    'currency' => 'USD', 'status' => 'active', 'name' => 'Subclassed', 'in_stock' => true,
                    'store_ids' => ['1'], 'discontinue_on' => 0, 'units_sold_count' => 0 }]
    end
    allow(provider).to receive(:presenter_class).and_return(subclass)
    yield_batches([product(1)])

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

  # On the 0.2.0 layout the real collection is dropped before the alias can
  # take its name; a blip creating the alias then would leave no index.
  it 'retries pointing the alias once after dropping a 0.2.0 collection' do
    typesense_client.collections.create(described_class::Schema.definition('products_shop'))
    attempts = 0
    allow(provider.send(:index_layout)).to receive(:point!).and_wrap_original do |original, name, target|
      attempts += 1 if name == 'products_shop'
      raise Typesense::Error::ServerError, 'blip' if name == 'products_shop' && attempts == 1

      original.call(name, target)
    end
    yield_batches([product(1)])

    provider.reindex(relation)

    expect(layout.alias_target('products_shop')).to match(layout.version_pattern)
    expect(live_ids).to eq(['prod_1_en_USD'])
  end

  # Once the alias points at the new collection the reindex has succeeded;
  # failing to drop what it replaced must not make the rake task fail.
  it 'succeeds, and says so, when dropping a replaced collection fails' do
    yield_batches([product(1)])
    provider.reindex(relation)
    allow(provider.send(:index_layout)).to receive(:drop!).and_raise(Typesense::Error::ServerError, 'busy')

    expect(provider.reindex(relation)).to eq(1)
    expect(layout.versioned_collections.size).to eq(2)
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

  # Reindexes can overlap: someone runs `rake spree:search:reindex` while the
  # deploy hook's is still going, say. There is one `__building` marker, and
  # the reindex that started last holds it, so only that one receives
  # single-product writes from then on, and only that one may go live (#22).
  describe 'when a newer reindex starts while one is running' do
    let(:logged) { [] }

    before do
      logger = Logger.new(File::NULL)
      %i[info warn error].each { |level| allow(logger).to receive(level) { |msg = nil, &blk| logged << (msg || blk&.call) } }
      allow(Rails).to receive(:logger).and_return(logger)
    end

    # What a reindex does first: create its collection, then take the marker.
    def start_newer_reindex
      newer = layout.new_version_name(now_ms + 60_000)
      typesense_client.collections.create(described_class::Schema.definition(newer))
      layout.point!('products_shop__building', newer)
      newer
    end

    it 'gives way: drops its own collection, leaves the live alias and the newer marker, and indexes nothing' do
      yield_batches([product(1)])
      provider.reindex(relation)
      live = layout.alias_target('products_shop')
      newer = nil
      allow(relation).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
        block.call([product(2)])
        newer = start_newer_reindex
      end

      expect(provider.reindex(relation)).to eq(0)
      expect(layout.alias_target('products_shop')).to eq(live)
      expect(layout.alias_target('products_shop__building')).to eq(newer)
      expect(layout.versioned_collections).to contain_exactly(live, newer)
      expect(live_ids).to eq(['prod_1_en_USD'])
      expect(logged.grep(/newer reindex/)).not_to be_empty
    end

    # The newer reindex finishing first drops this one's collection, as it
    # drops every collection older than its own.
    it 'gives way when the newer reindex has already gone live and dropped its collection' do
      yield_batches([product(1)])
      provider.reindex(relation)
      newer = described_class.new(store)
      allow(newer).to receive(:presenter_class).and_return(provider.send(:presenter_class))
      allow(relation).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
        block.call([product(2)])
        sleep 0.01 # a later millisecond, so the newer collection's name sorts after this one's
        newer.reindex(relation_yielding([product(3)]))
        block.call([product(4)])
      end

      expect(provider.reindex(relation)).to eq(0)
      expect(live_ids).to eq(['prod_3_en_USD'])
      expect(layout.versioned_collections).to eq([layout.alias_target('products_shop')])
      expect(layout.alias_target('products_shop__building')).to be_nil
    end

    # The newer reindex can fail instead: it removes the marker and drops its
    # collection, and nothing newer goes live. This one has still missed the
    # writes made while the newer one held the marker, so it must neither go
    # live nor end as though all were well.
    it 'raises, leaving the live alias as it was, when the newer reindex failed' do
      yield_batches([product(1)])
      provider.reindex(relation)
      live = layout.alias_target('products_shop')
      newer = described_class.new(store)
      allow(relation).to receive(:find_in_batches).with(batch_size: 500) do |**, &block|
        block.call([product(2)])
        sleep 0.01 # a later millisecond, so the newer collection's name sorts after this one's
        failing = relation_yielding
        allow(failing).to receive(:find_in_batches).and_raise('the newer reindex failed')
        expect { newer.reindex(failing) }.to raise_error('the newer reindex failed')
      end

      expect { provider.reindex(relation) }.to raise_error(described_class::ReindexOverlapError, /run the reindex again/)
      expect(layout.alias_target('products_shop')).to eq(live)
      expect(layout.alias_target('products_shop__building')).to be_nil
      expect(layout.versioned_collections).to eq([live])
      expect(live_ids).to eq(['prod_1_en_USD'])
    end

    it 'gives way, rather than raising, when it fails after a newer reindex took the marker' do
      yield_batches([product(1)])
      provider.reindex(relation)
      live = layout.alias_target('products_shop')
      newer = nil
      allow(relation).to receive(:find_in_batches).with(batch_size: 500) do
        newer = start_newer_reindex
        raise 'database went away'
      end

      expect(provider.reindex(relation)).to eq(0)
      expect(layout.alias_target('products_shop')).to eq(live)
      expect(layout.alias_target('products_shop__building')).to eq(newer)
      expect(layout.versioned_collections).to contain_exactly(live, newer)
      expect(logged.grep(/database went away/)).not_to be_empty
    end

    # A newer reindex can start between this one's last look at the marker
    # and its removing it. It must keep the marker, and its collection.
    it 'leaves the marker of a reindex that starts while this one goes live' do
      yield_batches([product(1)])
      newer = nil
      allow(provider.send(:index_layout)).to receive(:point!).and_wrap_original do |original, name, target|
        original.call(name, target)
        newer = start_newer_reindex if name == 'products_shop' && newer.nil?
      end

      provider.reindex(relation)

      expect(layout.alias_target('products_shop__building')).to eq(newer)
      expect(collection_names).to include(newer)
    end
  end

  # A product saved during a reindex is written to the collection being
  # built too, through the marker. When that write lands after the reindex
  # read the product but before it imports the batch, the batch's document
  # is the older one, and must not replace the write's (#23).
  describe 'when a product is saved while the reindex holds an older read of it' do
    let(:saved) { double('Spree::Product#1 (saved)', id: 1, prefixed_id: 'prod_1') }

    before { bootstrap_index!(provider) }

    # Building product 1's document from the batch runs `write` first: a save
    # whose index job lands between the reindex's read and its import.
    def stub_presenter_writing_midway(write, saved_documents: [doc_for(1, name: 'Renamed mid-reindex')])
      presenter_class = class_double('Spree::Typesense::ProductPresenter')
      allow(provider).to receive(:presenter_class).and_return(presenter_class)
      allow(presenter_class).to receive(:new) do |p, _store|
        next instance_double(Spree::Typesense::ProductPresenter, call: saved_documents) if p.equal?(saved)

        presenter = instance_double(Spree::Typesense::ProductPresenter)
        allow(presenter).to receive(:call) do
          write.call if p.id == 1
          [doc_for(p.id)]
        end
        presenter
      end
    end

    it "keeps the save's document, and does not count the batch's" do
      yield_batches([product(1), product(2)])
      stub_presenter_writing_midway(-> { provider.index(saved) })

      expect(provider.reindex(relation)).to eq(1)
      expect(live_names).to eq('prod_1_en_USD' => 'Renamed mid-reindex', 'prod_2_en_USD' => 'Product 2')
    end

    it 'still replaces a document written from a read older than the batch' do
      yield_batches([product(1)])
      stub_presenter_writing_midway(lambda {
        building = layout.alias_target('products_shop__building')
        provider.send(:index_batch, [doc_for(1, name: 'Written from an older read')], into: building, indexed_at: 0)
      })

      expect(provider.reindex(relation)).to eq(1)
      expect(live_names).to eq('prod_1_en_USD' => 'Product 1')
    end

    # A deletion leaves no document stamped `indexed_at` to compare with, so
    # it leaves a removal marker in the collection being built instead (#27).
    context 'when the save removes the product' do
      it 'leaves out a product deleted since the batch was read' do
        yield_batches([product(1), product(2)])
        stub_presenter_writing_midway(-> { provider.remove(saved) })

        expect(provider.reindex(relation)).to eq(1)
        expect(live_ids).to eq(%w[prod_2_en_USD])
      end

      it 'leaves out a product saved into producing no documents since the batch was read' do
        yield_batches([product(1), product(2)])
        stub_presenter_writing_midway(-> { provider.index(saved) }, saved_documents: [])

        expect(provider.reindex(relation)).to eq(1)
        expect(live_ids).to eq(%w[prod_2_en_USD])
      end

      it 'still indexes a product removed before the batch was read' do
        yield_batches([product(1)])
        stub_presenter_writing_midway(lambda {
          building = layout.alias_target('products_shop__building')
          provider.send(:mark_removed, 'prod_1', into: building, removed_at: 0)
        })

        expect(provider.reindex(relation)).to eq(1)
        expect(live_ids).to eq(%w[prod_1_en_USD])
      end

      it 'leaves no removal marker in the live collection' do
        yield_batches([product(1)])
        stub_presenter_writing_midway(-> { provider.remove(saved) })

        provider.reindex(relation)

        expect(typesense_client.collections[provider.collection_name].retrieve['num_documents']).to eq(0)
      end
    end
  end
end
