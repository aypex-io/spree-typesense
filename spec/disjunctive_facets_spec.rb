require 'spec_helper'

# Disjunctive faceting: when a user has selected option values, the counts for
# THAT option type must be computed with that type's own filter removed.
# Otherwise selecting "Red" reports every other colour as zero and the UI can
# never offer a second choice.
RSpec.describe Spree::SearchProvider::Typesense, 'disjunctive faceting' do
  let(:store)    { instance_double('Spree::Store', id: 7, code: 'shopdisj') }
  let(:provider) { described_class.new(store) }

  # One option type (Colour), three products: two Red, one Blue.
  let(:colour) { FakeOptionType.new(prefixed_id: 'optt_colour', name: 'Colour', label: 'Colour', kind: 'color') }
  let(:red) do
    FakeOptionValue.new(id: 'red', prefixed_id: 'ov_red', name: 'red', label: 'Red', position: 1,
                        color_code: '#f00', option_type_id: 1, option_type: colour,
                        image: FakeImage.new(attached: false))
  end
  let(:blue) do
    FakeOptionValue.new(id: 'blue', prefixed_id: 'ov_blue', name: 'blue', label: 'Blue', position: 2,
                        color_code: '#00f', option_type_id: 1, option_type: colour,
                        image: FakeImage.new(attached: false))
  end

  def doc(pid, option_value_ids)
    { 'id' => "#{pid}_en_USD", 'product_id' => pid, 'locale' => 'en', 'currency' => 'USD',
      'name' => "Product #{pid}", 'status' => 'active', 'in_stock' => true,
      'store_ids' => ['7'], 'discontinue_on' => 0, 'units_sold_count' => 0,
      'price' => 10.0, 'option_value_ids' => option_value_ids,
      'option_value_combination_ids' => single_variant_tokens(option_value_ids),
      'available_on' => '2020-01-01T00:00:00Z', 'created_at' => '2020-01-01T00:00:00Z' }
  end

  # The tokens a product with one variant carrying all these values gets.
  def single_variant_tokens(ids)
    (2..ids.size).flat_map { |n| ids.combination(n).map { |c| described_class::QueryBuilder.combination_token(c) } }
  end

  before do
    reset_typesense_index!(store.code)
    bootstrap_index!(provider)
    allow(provider).to receive(:locale).and_return('en')
    allow(provider).to receive(:currency).and_return('USD')
    provider.index_batch([
      doc('prod_1', ['ov_red']),
      doc('prod_2', ['ov_red']),
      doc('prod_3', ['ov_blue'])
    ])
    stub_ar_lookup(Spree::OptionValue, [red, blue])
    stub_ar_lookup(category_class, [])
  end

  def option_facet(result)
    result.filters.find { |f| f[:id] == 'optt_colour' }
  end

  def counts(result)
    option_facet(result)[:options].to_h { |o| [o[:id], o[:count]] }
  end

  context 'with ov_red selected' do
    subject(:result) do
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'])
      provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3]),
                       filters: { 'with_option_value_ids' => ['ov_red'] })
    end

    # THE TEST THAT MATTERS. A single-query implementation reports ov_blue as
    # absent/0 because the main query is filtered to ov_red.
    it 'still reports the true count for the unselected value of the same type' do
      expect(counts(result)['ov_blue']).to eq(1)
    end

    it 'keeps the selected value at its own filtered count' do
      expect(counts(result)['ov_red']).to eq(2)
    end

    # The main query IS still filtered — only the facet counts are widened.
    it 'leaves the result set itself filtered to the selection' do
      expect(result.total_count).to eq(2)
    end
  end

  context 'across two option types' do
    let(:size) { FakeOptionType.new(prefixed_id: 'optt_size', name: 'Size', label: 'Size', kind: 'text') }
    let(:small) do
      FakeOptionValue.new(id: 'small', prefixed_id: 'ov_small', name: 'small', label: 'Small', position: 1,
                          color_code: nil, option_type_id: 2, option_type: size,
                          image: FakeImage.new(attached: false))
    end
    let(:large) do
      FakeOptionValue.new(id: 'large', prefixed_id: 'ov_large', name: 'large', label: 'Large', position: 2,
                          color_code: nil, option_type_id: 2, option_type: size,
                          image: FakeImage.new(attached: false))
    end

    before do
      reset_typesense_index!(store.code)
      bootstrap_index!(provider)
      provider.index_batch([
        doc('prod_1', %w[ov_red ov_small]),
        doc('prod_2', %w[ov_red ov_large]),
        doc('prod_3', %w[ov_blue ov_small])
      ])
      stub_ar_lookup(Spree::OptionValue, [red, blue, small, large])
    end

    subject(:result) do
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'], 2 => ['ov_small'])
      provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3]),
                       filters: { 'with_option_value_ids' => %w[ov_red ov_small] })
    end

    # Colour counts drop the colour filter but KEEP the size filter:
    # size=small leaves prod_1 (red) and prod_3 (blue) -> red 1, blue 1.
    it 'relaxes only the facet\'s own type, keeping other types applied' do
      colour_counts = result.filters.find { |f| f[:id] == 'optt_colour' }[:options].to_h { |o| [o[:id], o[:count]] }
      expect(colour_counts).to eq('ov_red' => 1, 'ov_blue' => 1)
    end

    it 'counts only the products with a variant of both selected values' do
      expect(result.total_count).to eq(1)
    end

    # Size counts drop the size filter but KEEP colour=red:
    # colour=red leaves prod_1 (small) and prod_2 (large) -> small 1, large 1.
    it 'does the same for the second type' do
      size_counts = result.filters.find { |f| f[:id] == 'optt_size' }[:options].to_h { |o| [o[:id], o[:count]] }
      expect(size_counts).to eq('ov_small' => 1, 'ov_large' => 1)
    end
  end

  # With three types selected, each type's relaxed search must drop only its
  # own selection and keep BOTH others, and each type's counts must come from
  # its own search. Two types cannot tell those apart from keeping only the
  # first or the last other type, or from reading the wrong search's counts.
  # Each relaxed search here asks for two-value combination tokens (#25).
  context 'across three option types' do
    let(:size) { FakeOptionType.new(prefixed_id: 'optt_size', name: 'Size', label: 'Size', kind: 'text') }
    let(:material) do
      FakeOptionType.new(prefixed_id: 'optt_material', name: 'Material', label: 'Material', kind: 'text')
    end

    def value(name, type_id, type, position)
      FakeOptionValue.new(id: name, prefixed_id: "ov_#{name}", name: name, label: name.capitalize,
                          position: position, color_code: nil, option_type_id: type_id, option_type: type,
                          image: FakeImage.new(attached: false))
    end

    # A product with these variants, each a list of option value ids.
    def doc_with_variants(pid, *variants)
      doc(pid, variants.flatten.uniq).merge(
        'option_value_combination_ids' => variants.flat_map { |ids| single_variant_tokens(ids) }.uniq
      )
    end

    before do
      reset_typesense_index!(store.code)
      bootstrap_index!(provider)
      provider.index_batch([
        doc('prod_1', %w[ov_red ov_small ov_cotton]),
        doc('prod_2', %w[ov_blue ov_small ov_cotton]),
        doc('prod_3', %w[ov_red ov_large ov_cotton]),
        doc('prod_4', %w[ov_red ov_large ov_cotton]),
        doc('prod_5', %w[ov_red ov_small ov_wool]),
        doc('prod_6', %w[ov_red ov_small ov_wool]),
        doc('prod_7', %w[ov_red ov_small ov_wool]),
        doc('prod_8', %w[ov_green ov_large ov_wool]),
        # Small and cotton, but never on one variant: no colour count for it.
        doc_with_variants('prod_9', %w[ov_blue ov_small ov_wool], %w[ov_green ov_large ov_cotton])
      ])
      green = value('green', 1, colour, 3)
      stub_ar_lookup(Spree::OptionValue, [red, blue, green, value('small', 2, size, 1), value('large', 2, size, 2),
                                          value('cotton', 3, material, 1), value('wool', 3, material, 2)])
    end

    subject(:result) do
      allow(provider).to receive(:group_option_values_by_type)
        .and_return(1 => ['ov_red'], 2 => ['ov_small'], 3 => ['ov_cotton'])
      provider.filters(scope: FakeScope.new((1..9).map { |n| "prod_#{n}" }),
                       filters: { 'with_option_value_ids' => %w[ov_red ov_small ov_cotton] })
    end

    def counts_for(type_id)
      result.filters.find { |f| f[:id] == type_id }[:options].to_h { |o| [o[:id], o[:count]] }
    end

    it 'counts only the products with a variant of all three selected values' do
      expect(result.total_count).to eq(1)
    end

    # Small and cotton on one variant: prod_1 (red) and prod_2 (blue).
    it 'counts colours keeping both size and material' do
      expect(counts_for('optt_colour')).to eq('ov_red' => 1, 'ov_blue' => 1)
    end

    # Red and cotton on one variant: prod_1 (small), prod_3 and prod_4 (large).
    it 'counts sizes keeping both colour and material' do
      expect(counts_for('optt_size')).to eq('ov_small' => 1, 'ov_large' => 2)
    end

    # Red and small on one variant: prod_1 (cotton), prod_5 to prod_7 (wool).
    it 'counts materials keeping both colour and size' do
      expect(counts_for('optt_material')).to eq('ov_cotton' => 1, 'ov_wool' => 3)
    end
  end

  # A value's count is the number of products choosing it would list: those
  # with a variant carrying it together with the other types' selected
  # values, not those carrying it on any variant (#19).
  context 'counting by variant' do
    let(:size) { FakeOptionType.new(prefixed_id: 'optt_size', name: 'Size', label: 'Size', kind: 'text') }

    def size_value(name, position)
      FakeOptionValue.new(id: name, prefixed_id: "ov_#{name}", name: name, label: name.upcase, position: position,
                          color_code: nil, option_type_id: 2, option_type: size, image: FakeImage.new(attached: false))
    end

    def doc_with_variants(pid, *variants)
      doc(pid, variants.flatten.uniq).merge(
        'option_value_combination_ids' => variants.flat_map { |ids| single_variant_tokens(ids) }.uniq
      )
    end

    let(:option_values) { [red, blue, size_value('s', 1), size_value('xl', 2)] }

    before do
      reset_typesense_index!(store.code)
      bootstrap_index!(provider)
      provider.index_batch([
        # Blue and XL, but never on one variant.
        doc_with_variants('prod_1', %w[ov_blue ov_s], %w[ov_red ov_xl]),
        doc_with_variants('prod_2', %w[ov_blue ov_xl]),
        doc_with_variants('prod_3', %w[ov_blue ov_xl], %w[ov_red ov_xl]),
        doc_with_variants('prod_4', %w[ov_red ov_s])
      ])
      stub_ar_lookup(Spree::OptionValue, option_values)
    end

    def facets_for(grouped)
      allow(provider).to receive(:group_option_values_by_type).and_return(grouped)
      provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3 prod_4]),
                       filters: { 'with_option_value_ids' => grouped.values.flatten })
    end

    def counts_for(result, type_id)
      result.filters.find { |f| f[:id] == type_id }[:options].to_h { |o| [o[:id], o[:count]] }
    end

    it "counts another type's values by variant: with Blue selected, a Red XL beside a Blue S is no XL" do
      expect(counts_for(facets_for(1 => %w[ov_blue]), 'optt_size')).to eq('ov_s' => 1, 'ov_xl' => 2)
    end

    it 'counts each value as choosing it would list' do
      xl_count = counts_for(facets_for(1 => %w[ov_blue]), 'optt_size')['ov_xl']

      expect(facets_for(1 => %w[ov_blue], 2 => %w[ov_xl]).total_count).to eq(xl_count)
    end

    it "counts the selected types' own values by variant too" do
      result = facets_for(1 => %w[ov_blue], 2 => %w[ov_xl])

      expect(counts_for(result, 'optt_colour')).to eq('ov_blue' => 2, 'ov_red' => 2)
      expect(counts_for(result, 'optt_size')).to eq('ov_s' => 1, 'ov_xl' => 2)
    end

    it 'counts a product once when it has the value with several selected values of another type' do
      expect(counts_for(facets_for(1 => %w[ov_blue ov_red]), 'optt_size')).to eq('ov_s' => 2, 'ov_xl' => 3)
    end

    it "takes a lone selected type's own counts from the first request, and counts the others' in one more" do
      allow(provider).to receive(:execute_multi_search).and_call_original

      expect(counts_for(facets_for(1 => %w[ov_blue]), 'optt_colour')).to eq('ov_blue' => 3, 'ov_red' => 3)
      expect(provider).to have_received(:execute_multi_search).twice
    end

    # Typesense takes at most 50 searches in one multi_search.
    context 'with more values than one multi_search can count' do
      let(:sizes) { (1..60).map { |n| size_value("size#{n}", n) } }
      let(:option_values) { [red, blue, *sizes] }

      before do
        reset_typesense_index!(store.code)
        bootstrap_index!(provider)
        provider.index_batch(sizes.each_with_index.map do |value, index|
          # Every product is Blue; only the even ones in their own size.
          blue_variant = index.even? ? %w[ov_blue] + [value.prefixed_id] : %w[ov_blue]
          doc_with_variants("prod_#{index}", blue_variant, ['ov_red', value.prefixed_id])
        end)
      end

      it 'counts every value by variant' do
        allow(provider).to receive(:group_option_values_by_type).and_return(1 => %w[ov_blue])
        result = provider.filters(scope: FakeScope.new((0...60).map { |n| "prod_#{n}" }),
                                  filters: { 'with_option_value_ids' => %w[ov_blue] })

        expect(counts_for(result, 'optt_size')).to eq(sizes.each_slice(2).to_h { |even, _odd| [even.prefixed_id, 1] })
      end
    end
  end

  # THE SHARPEST ENGINE DIVERGENCE IN THIS GEM. A single search raises
  # Typesense::Error::* on a bad filter or a missing collection; multi_search
  # answers HTTP 200 and puts {error, code} in the individual sub-result. A
  # rescue-only error path would therefore serve wrong counts with no signal.
  # A failed sub-search answers from the Database provider, as any other
  # Typesense failure does. These specs pin that.
  context 'when a multi_search sub-result carries an error body' do
    let(:ok_sub_result) do
      { 'found' => 2, 'hits' => [],
        'facet_counts' => [{ 'field_name' => 'option_value_ids',
                             'counts' => [{ 'value' => 'ov_red', 'count' => 2 }] }] }
    end
    let(:database) { instance_double(Spree::SearchProvider::Database, filters: :database_filters) }

    before { allow(Spree::SearchProvider::Database).to receive(:new).and_return(database) }

    def stub_multi_search(results)
      multi = instance_double('Typesense::MultiSearch')
      allow(multi).to receive(:perform).and_return('results' => results)
      allow(provider.search_client).to receive(:multi_search).and_return(multi)
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'])
    end

    subject(:result) { provider.filters(scope: FakeScope.new(%w[prod_1])) }

    # POSITIVE CONTROL: proves the stub really does drive the multi_search path,
    # so the failure specs below cannot pass just because nothing ran.
    it 'builds facets normally when every sub-result succeeds' do
      stub_multi_search([ok_sub_result, ok_sub_result])
      expect(result.filters.find { |f| f[:id] == 'optt_colour' }[:options].first[:count]).to eq(2)
    end

    # The whole point: a partial failure must NOT quietly fall through to the
    # main query's counts, which are exactly the wrong ones (every unselected
    # value reads zero) — that is the bug disjunctive faceting exists to fix.
    it 'answers from the Database provider when a LATER sub-result errors' do
      stub_multi_search([ok_sub_result, { 'error' => 'Bad filter', 'code' => 400 }])
      expect(result).to eq(:database_filters)
    end

    it 'does the same when the MAIN sub-result errors' do
      stub_multi_search([{ 'error' => 'Collection not found', 'code' => 404 }, ok_sub_result])
      expect(result).to eq(:database_filters)
    end

    # The count searches run after the faceted ones (#19).
    it 'does the same when a count search errors' do
      multi = instance_double('Typesense::MultiSearch')
      allow(multi).to receive(:perform).and_return({ 'results' => [ok_sub_result] * 3 },
                                                   { 'results' => [{ 'error' => 'Bad filter', 'code' => 400 }] })
      allow(provider.search_client).to receive(:multi_search).and_return(multi)
      allow(provider).to receive(:group_option_values_by_type).and_return(1 => ['ov_red'], 2 => ['ov_small'])

      expect(result).to eq(:database_filters)
      expect(multi).to have_received(:perform).twice
    end

    it 'does not raise' do
      stub_multi_search([ok_sub_result, { 'error' => 'Bad filter', 'code' => 400 }])
      expect { result }.not_to raise_error
    end
  end

  context 'with nothing selected' do
    it 'issues a single search rather than paying for a multi_search' do
      allow(provider).to receive(:group_option_values_by_type).and_return({})
      expect(provider).not_to receive(:execute_multi_search)
      result = provider.filters(scope: FakeScope.new(%w[prod_1 prod_2 prod_3]))
      expect(counts(result)).to eq('ov_red' => 2, 'ov_blue' => 1)
    end
  end
end
