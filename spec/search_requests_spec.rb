require 'spec_helper'

# What the provider asks Typesense for, and what it does with the answer,
# with a recording client in place of the server. What Typesense does with
# the same requests is pinned against the real server in search_spec.rb.
RSpec.describe Spree::SearchProvider::Typesense, 'search requests' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'shop') }
  let(:provider) { described_class.new(store) }
  let(:client)   { RecordingTypesenseClient.new }

  def hits(*product_ids)
    { 'found' => product_ids.size, 'hits' => product_ids.map { |pid| { 'document' => { 'product_id' => pid } } },
      'facet_counts' => [] }
  end

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    allow(provider).to receive(:search_client).and_return(client)
  end

  # Core's storefront scope narrows to the current channel's publications
  # (`for_channel(Spree::Current.channel)`), as Meilisearch's filter does.
  # Without it the listing would count and paginate products the channel
  # does not sell.
  describe 'the current channel' do
    let(:channel) { Struct.new(:id).new(3) }

    it 'scopes searches to it' do
      allow(Spree::Current).to receive(:channel).and_return(channel)

      provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(client.searches.sole[:filter_by]).to include('channel_ids:=`3`')
    end

    it 'scopes facets to it' do
      allow(Spree::Current).to receive(:channel).and_return(channel)

      provider.filters(scope: FakeScope.new([]))

      expect(client.searches.sole[:filter_by]).to include('channel_ids:=`3`')
    end

    it 'adds no channel filter when there is no current channel' do
      provider.search_and_filter(scope: FakeScope.new([]), query: 'x')

      expect(client.searches.sole[:filter_by]).not_to include('channel_ids')
    end
  end

  # The filters endpoint advertises the sorts a listing offers and which one
  # it starts on, as the Database provider's FiltersAggregator does.
  describe '#filters sort options and default sort' do
    def collection(sort_order) = Struct.new(:sort_order, :prefixed_id).new(sort_order, 'coll_summer')

    it "offers 'manual', as the Database provider does, ahead of the field sorts" do
      expect(provider.filters(scope: FakeScope.new([])).sort_options).to eq(
        %w[manual price -price name -name -available_on available_on best_selling].map { |id| { id: id, label: nil } }
      )
    end

    it "defaults to 'manual' outside a collection" do
      expect(provider.filters(scope: FakeScope.new([])).default_sort).to eq('manual')
    end

    {
      'price asc' => 'price', 'price desc' => '-price', 'name desc' => '-name', 'available_on desc' => '-available_on',
      'best_selling' => 'best_selling', 'manual' => 'manual', nil => 'manual'
    }.each do |sort_order, api_sort|
      it "defaults a collection sorted #{sort_order.inspect} to #{api_sort.inspect}" do
        result = provider.filters(scope: FakeScope.new([]), filters: { '_collection' => collection(sort_order) })

        expect(result.default_sort).to eq(api_sort)
      end
    end

    # Spree 6 categories are manual only: a category page starts on
    # 'manual', whatever sort order a category migrated from 5.x carries.
    describe 'on a category page' do
      def category(sort_order) = Struct.new(:sort_order, :prefixed_id).new(sort_order, 'ctg_tea')

      def default_for(sort_order)
        provider.filters(scope: FakeScope.new([]), filters: { '_category' => category(sort_order) }).default_sort
      end

      context 'on Spree 6.x' do
        it "ignores the category's sort order" do
          expect(default_for('price desc')).to eq('manual')
        end
      end
    end

    it 'reads a symbol-keyed _collection too' do
      result = provider.filters(scope: FakeScope.new([]), filters: { _collection: collection('price desc') })

      expect(result.default_sort).to eq('-price')
    end
  end

  # Spree 6's Database provider orders a single category or collection by the
  # merchant's positions when the sort is 'manual', or omitted there, whatever
  # the text query. Spree 6 documents carry `pos_<grouping id>`, so Typesense
  # sorts those listings itself (#5).
  describe '#search_and_filter on a manually sorted listing' do
    let(:database) { instance_double(Spree::SearchProvider::Database, search_and_filter: :database_result) }
    let(:scope) { FakeScope.new([]) }

    before { allow(Spree::SearchProvider::Database).to receive(:new).and_return(database) }

    def search(**args) = provider.search_and_filter(scope: scope, page: 2, limit: 10, **args)
    def sort_sent = client.searches.sole[:sort_by]

    context 'on Spree 6.x' do
      [
        [{ 'in_category' => 'ctg_a' }, nil, 'pos_ctg_a:asc'],
        [{ 'in_category' => 'ctg_a' }, '', 'pos_ctg_a:asc'],
        [{ 'in_collection' => 'coll_a' }, nil, 'pos_coll_a:asc'],
        [{ 'in_collection' => 'coll_a' }, 'manual', 'pos_coll_a:asc'],
        [{ in_collection: 'coll_a', 'price_gte' => '5' }, 'manual', 'pos_coll_a:asc']
      ].each do |filters, sort, sort_by|
        it "sorts #{filters.inspect} sorted #{sort.inspect} by #{sort_by} in Typesense" do
          search(filters: filters, sort: sort)

          expect(sort_sent).to eq(sort_by)
          expect(database).not_to have_received(:search_and_filter)
        end
      end

      it 'sorts by position under a text query too, as core does' do
        search(query: 'tea', filters: { 'in_category' => 'ctg_a' })

        expect(sort_sent).to eq('pos_ctg_a:asc')
      end

      it 'follows the collection when a collection and a category are both given, as core does' do
        search(filters: { 'in_category' => 'ctg_a', 'in_collection' => 'coll_b' })

        expect(sort_sent).to eq('pos_coll_b:asc')
      end
    end

    # A field sort is Typesense's to apply, and without one grouping 'manual'
    # has no positions to follow. (An invalid grouping id never reaches
    # Typesense: the Database provider answers it; see
    # unanswered_filters_spec.rb.)
    [
      ['a field sort', { filters: { 'in_collection' => 'coll_a' }, sort: 'price' }, 'price:asc'],
      ["'manual' with no grouping", { sort: 'manual' }, nil],
      ['several categories', { filters: { 'in_categories' => %w[ctg_a ctg_b] } }, nil]
    ].each do |description, args, sort_by|
      it "sends #{description} #{sort_by ? "sorted by #{sort_by}" : 'with no sort'}" do
        search(**args)

        expect(sort_sent).to eq(sort_by)
      end
    end
  end
end

# Selecting values of two or more option types means one variant carrying a
# value of each ("blue AND XL" is a product that sells a blue XL), as core's
# `Product.with_option_value_ids` decides on Spree 6. The index holds each
# product's values as one set, so it can only pre-filter: the authorized scope
# is narrowed through core's scope before intersecting, as Spree's Meilisearch
# provider does when its index cannot answer exactly.
RSpec.describe Spree::SearchProvider::Typesense, 'search requests across option types' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'shop') }
  let(:provider) { described_class.new(store) }
  let(:scope)    { FakeScope.new(%w[prod_1 prod_2 prod_3]) }
  let(:client) do
    RecordingTypesenseClient.new do |_kind, _params|
      { 'found' => 3, 'hits' => %w[prod_1 prod_2 prod_3].map { |pid| { 'document' => { 'product_id' => pid } } } }
    end
  end

  before do
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    allow(provider).to receive(:search_client).and_return(client)
  end

  def search(grouped)
    allow(provider).to receive(:group_option_values_by_type).and_return(grouped)
    provider.search_and_filter(scope: scope, filters: { 'with_option_value_ids' => grouped.values.flatten })
  end

  # Spree 6 documents carry one token per combination of a variant's values,
  # so Typesense answers "blue AND XL" exactly: full pages, exact totals (#10).
  context 'on Spree 6.x' do
    it 'asks Typesense for the combinations, and leaves the scope alone' do
      allow(scope).to receive(:with_option_value_ids)

      result = search(1 => %w[ov_blue], 2 => %w[ov_xl ov_l])

      expect(client.searches.sole[:filter_by])
        .to include('option_value_combination_ids:=[`ov_blue|ov_xl`,`ov_blue|ov_l`]')
      expect(client.searches.sole[:filter_by]).not_to include('option_value_ids:=')
      expect(scope).not_to have_received(:with_option_value_ids)
      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1 prod_2 prod_3])
    end

    it 'narrows through core when more types are selected than the tokens cover' do
      allow(scope).to receive(:with_option_value_ids).and_return(FakeScope.new(%w[prod_2]))
      grouped = (1..7).to_h { |type| [type, ["ov_#{type}"]] }

      result = search(grouped)

      expect(scope).to have_received(:with_option_value_ids).with(grouped.values.flatten)
      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_2])
    end
  end

  # One type is a union of values, which the index answers exactly.
  it 'leaves the scope alone when the values are all of one option type' do
    allow(scope).to receive(:with_option_value_ids)

    result = search(1 => %w[ov_blue ov_red])

    expect(scope).not_to have_received(:with_option_value_ids)
    expect(result.products.map(&:prefixed_id)).to eq(%w[prod_1 prod_2 prod_3])
  end

  it 'leaves the scope alone when no option value is selected' do
    allow(scope).to receive(:with_option_value_ids)

    search({})

    expect(scope).not_to have_received(:with_option_value_ids)
  end
end
