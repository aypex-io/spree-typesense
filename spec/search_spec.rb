require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, '#search_and_filter' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'shop') }
  let(:provider) { described_class.new(store) }

  def doc(pid, name:, locale: 'en', currency: 'USD', price: 10.0, available_on: '2020-01-01T00:00:00Z')
    { 'id' => "#{pid}_#{locale}_#{currency}", 'product_id' => pid,
      'locale' => locale, 'currency' => currency, 'name' => name,
      'status' => 'active', 'in_stock' => true, 'store_ids' => ['7'],
      'discontinue_on' => 0, 'units_sold_count' => 0, 'price' => price,
      'available_on' => available_on, 'created_at' => '2020-01-01T00:00:00Z' }
  end

  before do
    reset_typesense_index!(store.code)
    bootstrap_index!(provider)
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    provider.index_batch([
      doc('prod_1', name: 'Herbal Extract'),
      doc('prod_2', name: 'Creatine'),
      doc('prod_3', name: 'Herbal Capsules', locale: 'de', currency: 'EUR')
    ])
  end

  it 'returns a SearchResult of scope-intersected products' do
    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_2]), query: 'herbal')
    expect(result).to be_a(Spree::SearchProvider::SearchResult)
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1])
  end

  # A product removed while a reindex is building leaves a marker in that
  # collection (#27). One can reach the live collection, so no search may
  # return or count it.
  it 'never returns or counts a removal marker' do
    provider.send(:mark_removed, 'prod_1', into: provider.collection_name, removed_at: 0)
    scope = FakeScope.new(%w[prod_1 prod_2])

    result = provider.search_and_filter(scope: scope)

    expect(result.products.map(&:prefixed_id)).to contain_exactly('prod_1', 'prod_2')
    expect(result.total_count).to eq(2)
    expect(provider.filters(scope: scope).total_count).to eq(2)
  end

  # THE multi-market test: the German/EUR document must not leak into an en/USD search.
  it 'never returns another market\'s copy of a product' do
    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_3]), query: 'herbal')
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1])
  end

  # Locales such as en-US carry a hyphen, which the locale filter must quote.
  it 'finds documents in a hyphenated locale' do
    provider.index_batch([doc('prod_4', name: 'Herbal Tea', locale: 'en-US')])
    allow(provider).to receive(:locale).and_return('en-US')

    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_4]), query: 'herbal')

    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_4])
  end

  # One product sells blue-S and red-XL, another blue-XL: "blue AND XL" is
  # only the second, with an exact total, and the scope is never narrowed by
  # core (FakeScope raises if it is) (#10).
  context 'on Spree 6.x' do
    it 'filters values of two option types to products with one variant carrying both' do
      provider.index_batch([
        doc('prod_a', name: 'Herbal A').merge('option_value_ids' => %w[ov_blue ov_s ov_red ov_xl],
                                              'option_value_combination_ids' => %w[ov_blue|ov_s ov_red|ov_xl]),
        doc('prod_b', name: 'Herbal B').merge('option_value_ids' => %w[ov_blue ov_xl],
                                              'option_value_combination_ids' => %w[ov_blue|ov_xl])
      ])
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => %w[ov_blue], 2 => %w[ov_xl])

      result = provider.search_and_filter(scope: FakeScope.new(%w[prod_a prod_b]),
                                          filters: { 'with_option_value_ids' => %w[ov_blue ov_xl] })

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_b])
      expect(result.total_count).to eq(1)
    end
  end

  # The merchant's order inside Typesense: documents carry the product's
  # position in each grouping, and a manual listing sorts by it (#5).
  context 'a manually sorted listing on Spree 6.x' do
    it 'comes back in the order of the positions' do
      provider.index_batch([
        doc('prod_a', name: 'Herbal A').merge('collection_ids' => %w[coll_x], 'pos_coll_x' => 3),
        doc('prod_b', name: 'Herbal B').merge('collection_ids' => %w[coll_x], 'pos_coll_x' => 1),
        doc('prod_c', name: 'Herbal C').merge('collection_ids' => %w[coll_x], 'pos_coll_x' => 2)
      ])

      result = provider.search_and_filter(scope: FakeScope.new(%w[prod_a prod_b prod_c]),
                                          filters: { 'in_collection' => 'coll_x' })

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_b prod_c prod_a])
    end

    # Before the first 0.3.0 reindex, or for a grouping no indexed product
    # belongs to, no document carries the field: Typesense refuses the sort,
    # and the Database provider, which sorts by position too, answers. That
    # is expected, so it is not reported as an error.
    it 'answers from the Database provider, quietly, while no document carries the position' do
      provider.index_batch([doc('prod_a', name: 'Herbal A').merge('category_ids' => %w[ctg_x])])
      database = instance_double(Spree::SearchProvider::Database, search_and_filter: :database_result)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(database)
      allow(Spree::SearchProvider::NULL_ERROR_REPORTER).to receive(:report)

      result = provider.search_and_filter(scope: FakeScope.new(%w[prod_a]), filters: { 'in_category' => 'ctg_x' })

      expect(result).to eq(:database_result)
      expect(Spree::SearchProvider::NULL_ERROR_REPORTER).not_to have_received(:report)
    end
  end

  # A filter far longer than Typesense takes in a GET query string (4000
  # characters): 30 colours by 30 sizes make 900 combination tokens. The
  # search must still be answered by Typesense, not fall back.
  context 'a long filter on Spree 6.x' do
    it 'is answered by Typesense' do
      colours = (1..30).map { |i| "optval_colour#{i.to_s.rjust(4, '0')}" }
      sizes = (1..30).map { |i| "optval_size#{i.to_s.rjust(4, '0')}" }
      token = described_class::QueryBuilder.combination_token([colours.first, sizes.first])
      provider.index_batch([doc('prod_m', name: 'Herbal M').merge('option_value_ids' => [colours.first, sizes.first],
                                                                  'option_value_combination_ids' => [token])])
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => colours, 2 => sizes)
      allow(Spree::SearchProvider::Database).to receive(:new).and_return(instance_double(Spree::SearchProvider::Database))

      result = provider.search_and_filter(scope: FakeScope.new(%w[prod_m]),
                                          filters: { 'with_option_value_ids' => colours + sizes })

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_m])
    end
  end

  # THE security test.
  it 'never returns a product missing from the authorized scope' do
    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_2]), query: 'herbal')
    expect(result.products).to be_empty
  end

  # Correct results from the database beat an empty page; fallback_spec.rb
  # covers each kind of failure.
  it 'answers from the Database provider when the engine errors' do
    allow(provider).to receive(:execute_search).and_raise(Typesense::Error::ServerError, 'Internal Server Error')
    database = instance_double(Spree::SearchProvider::Database, search_and_filter: :database_result)
    allow(Spree::SearchProvider::Database).to receive(:new).and_return(database)

    expect(provider.search_and_filter(scope: FakeScope.new([]), query: 'x')).to eq(:database_result)
  end

  # Proves the available_on_i derived-field fix works end to end against a
  # live server, not just in unit isolation: a future-dated product must not
  # come back from a real search.
  it 'excludes a future-dated product from search results' do
    provider.index_batch([
      doc('prod_9', name: 'Herbal Future Batch', available_on: 1.year.from_now.iso8601)
    ])

    result = provider.search_and_filter(scope: FakeScope.new(%w[prod_1 prod_9]), query: 'herbal')

    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1])
  end

  # Core's storefront scope narrows to the products published on the current
  # channel; so do the listing, its count and its pages here.
  describe 'the current channel' do
    let(:scope) { FakeScope.new(%w[prod_20 prod_21 prod_22 prod_23]) }

    before do
      provider.index_batch([
        doc('prod_20', name: 'Channel Here').merge('channel_ids' => %w[3]),
        doc('prod_21', name: 'Channel Elsewhere').merge('channel_ids' => %w[4]),
        doc('prod_22', name: 'Channel Both').merge('channel_ids' => %w[3 4]),
        doc('prod_23', name: 'Channel Unpublished').merge('channel_ids' => [])
      ])
    end

    it 'returns and counts only the products published on it' do
      allow(Spree::Current).to receive(:channel).and_return(Struct.new(:id).new(3))

      result = provider.search_and_filter(scope: scope, query: 'channel')

      expect(result.products.map(&:prefixed_id)).to contain_exactly('prod_20', 'prod_22')
      expect(result.total_count).to eq(2)
    end

    it 'narrows nothing when there is no current channel' do
      result = provider.search_and_filter(scope: scope, query: 'channel')

      expect(result.total_count).to eq(4)
    end
  end

  # Core's storefront scope keeps a product scheduled to publish later when it
  # is on pre-order (`available(..., include_preorderable: true)`).
  describe 'pre-orders' do
    let(:scope) { FakeScope.new(%w[prod_10 prod_11 prod_12]) }

    before do
      provider.index_batch([
        doc('prod_10', name: 'Launch Edition', available_on: 1.year.from_now.iso8601).merge('preorder' => true),
        doc('prod_11', name: 'Launch Bundle', available_on: 1.year.from_now.iso8601).merge('preorder' => false),
        doc('prod_12', name: 'Launch Classic')
      ])
    end

    it 'returns a future-dated product that is on pre-order, and still excludes one that is not' do
      result = provider.search_and_filter(scope: scope, query: 'launch')

      expect(result.products.map(&:prefixed_id)).to contain_exactly('prod_10', 'prod_12')
      expect(result.total_count).to eq(2)
    end

    it 'counts the pre-order in the facets too' do
      expect(provider.filters(scope: scope, query: 'launch').total_count).to eq(2)
    end

    # A document without `preorder` (written by a release before it was
    # emitted) still serves: the schema declares it optional, so filtering on
    # it is valid and matches none of them, and the publish date alone
    # decides.
    it 'serves documents built without a preorder field' do
      stored = provider.client.collections[provider.collection_name].documents['prod_12_en_USD'].retrieve
      expect(stored).not_to have_key('preorder')

      result = provider.search_and_filter(scope: scope, query: 'classic')

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_12])
    end
  end

  # Spree 6.0 whitelists in_collection; a collection listing must not return
  # the whole catalogue, nor count or facet it.
  context 'filtering by collection on Spree 6.x' do
    before do
      provider.index_batch([
        doc('prod_4', name: 'Herbal Tea', price: 20.0).merge('collection_ids' => %w[coll_summer], 'pos_coll_summer' => 2),
        doc('prod_5', name: 'Herbal Gummies', price: 30.0)
          .merge('collection_ids' => %w[coll_summer coll_new], 'pos_coll_summer' => 1, 'pos_coll_new' => 1)
      ])
    end

    let(:scope) { FakeScope.new(%w[prod_1 prod_2 prod_4 prod_5]) }

    it 'returns and counts only the products in that collection' do
      result = provider.search_and_filter(scope: scope, filters: { in_collection: 'coll_summer' }, sort: 'price')

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_4 prod_5])
      expect(result.total_count).to eq(2)
    end

    it 'combines with a query' do
      result = provider.search_and_filter(scope: scope, query: 'gummies', filters: { in_collection: 'coll_summer' })

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_5])
    end

    it 'limits the facets and their total to the collection' do
      filters = provider.filters(scope: scope, filters: { in_collection: 'coll_new' })

      expect(filters.total_count).to eq(1)
      expect(filters.filters.find { |f| f[:id] == 'price' }).to include(min: 30.0, max: 30.0)
    end
  end
end
