require 'spec_helper'

RSpec.describe SpreeTypesense::ProductPresenter do
  let(:us) { FakeCatalog::Market.new(currency: 'USD', supported_locales_list: %w[en], default_locale: 'en') }
  let(:eu) { FakeCatalog::Market.new(currency: 'EUR', supported_locales_list: %w[en de], default_locale: 'en') }
  let(:store) do
    FakeCatalog::Store.new(id: 7, code: 'presenter', markets: [us, eu], default_market: us,
                           supported_currencies_list: [FakeCatalog::Currency.new('USD')])
  end

  # Spree 6.0 renamed Taxon to Category; both carry the ctg_ prefix.
  let(:category_prefix) { 'ctg' }
  let(:apparel) { FakeCatalog::Category.new(prefixed_id: "#{category_prefix}_apparel", names: { 'en' => 'Apparel' }) }
  let(:shirts) do
    FakeCatalog::Category.new(prefixed_id: "#{category_prefix}_shirts", names: { 'en' => 'Shirts', 'de' => 'Hemden' },
                              parent: apparel)
  end
  let(:sale) { FakeCatalog::Category.new(prefixed_id: "#{category_prefix}_sale", names: { 'en' => 'Sale' }, parent: apparel) }

  let(:red) do
    FakeCatalog::Option.new(prefixed_id: 'optv_red', presentations: { 'en' => 'Red (presentation)' },
                            labels: { 'en' => 'Red', 'de' => 'Rot' })
  end
  let(:large) do
    FakeCatalog::Option.new(prefixed_id: 'optv_large', presentations: { 'en' => 'L (presentation)' },
                            labels: { 'en' => 'Large' })
  end
  let(:colour) do
    FakeCatalog::Option.new(prefixed_id: 'opt_colour', presentations: { 'en' => 'Colour (presentation)' },
                            labels: { 'en' => 'Colour', 'de' => 'Farbe' })
  end

  def custom_field(key, value, field_type: 'short_text', searchable: true, sortable: false, storefront_visible: true)
    definition = FakeCatalog::CustomFieldDefinition.new(
      filter_key: "cf_#{key}", field_type: field_type, searchable: searchable, sortable: sortable,
      storefront_visible: storefront_visible
    )
    FakeCatalog::CustomField.new(definition: definition, value: value)
  end

  let(:custom_fields) do
    [
      custom_field('material', 'Cotton'),
      custom_field('weight', '250', field_type: 'number', searchable: false, sortable: true),
      custom_field('supplier_code', 'SUP-1', storefront_visible: false),
      custom_field('internal_note', 'not indexed', searchable: false, sortable: false)
    ]
  end

  let(:product) do
    FakeCatalog::Product.new(
      prefixed_id: 'prod_shirt',
      names: { 'en' => 'Linen Shirt', 'de' => 'Leinenhemd' },
      descriptions: { 'en' => '<p>Breathable</p><p>Made <strong>well</strong></p>' },
      slugs: { 'en' => 'linen-shirt' },
      prices: { 'USD' => BigDecimal('39.5'), 'EUR' => BigDecimal('36') },
      compare_at: { 'USD' => BigDecimal('49') },
      sku: 'SHIRT-1',
      preorder: true,
      store_id: 7,
      channel_ids_by_store_id: { 7 => [3, 4], 8 => [9] },
      discontinue_on: Time.utc(2030, 1, 1),
      categories: [shirts, sale],
      option_types: [colour],
      variants: [FakeCatalog::Variant.new(option_values: [red, large]), FakeCatalog::Variant.new(option_values: [red])],
      tag_list: %w[summer],
      units_sold_count: 12,
      available_on: Time.utc(2024, 1, 2),
      created_at: Time.utc(2023, 5, 6),
      updated_at: Time.utc(2024, 7, 8),
      custom_fields: custom_fields,
      collections: [FakeCatalog::Collection.new('coll_summer'), FakeCatalog::Collection.new('coll_linen')],
      positions: { 'coll_summer' => 3, 'coll_linen' => 1, 'ctg_shirts' => 4, 'ctg_sale' => 2 }
    )
  end

  subject(:documents) { described_class.new(product, store).call }

  def document(locale, currency)
    documents.find { |d| d[:locale] == locale && d[:currency] == currency }
  end

  it 'emits one document per market × locale the product is priced in' do
    expect(documents.map { |d| d[:id] }).to eq(%w[prod_shirt_en_USD prod_shirt_en_EUR prod_shirt_de_EUR])
  end

  it 'falls back to the default locale for untranslated fields' do
    expect(document('de', 'EUR')).to include(name: 'Leinenhemd', slug: 'linen-shirt')
  end

  it 'skips currencies the product has no price in, and emits nothing without any price' do
    unpriced = FakeCatalog::Product.new(prefixed_id: 'prod_none', names: { 'en' => 'Unpriced' })
    expect(described_class.new(unpriced, store).call).to eq([])
  end

  it 'falls back to the store default currency when the store has no markets' do
    legacy = FakeCatalog::Store.new(id: 7, code: 'legacy', markets: [], default_market: nil,
                                    supported_currencies_list: [FakeCatalog::Currency.new('USD')])
    docs = described_class.new(product, legacy).call
    expect(docs.map { |d| d[:id] }).to eq(['prod_shirt_en_USD'])
  end

  it 'scopes channel ids to the store being indexed' do
    expect(document('en', 'USD')[:channel_ids]).to eq(%w[3 4])
  end

  context 'on Spree 5.x', unless: SpreeTypesense.spree_6? do
    # The guarantee that 5.x documents are exactly what they were when core's
    # presenter built them: same product in, same documents out.
    describe 'parity with spree_core\'s own presenter' do
      def core_documents(product, store)
        Spree::SearchProvider::ProductPresenter.new(product, store).call
      end

      it 'matches for a multi-market, multi-locale product' do
        expect(documents).to eq(core_documents(product, store))
      end

      it 'matches for a store without markets' do
        legacy = FakeCatalog::Store.new(id: 7, code: 'legacy', markets: [], default_market: nil,
                                        supported_currencies_list: [FakeCatalog::Currency.new('USD')])
        expect(described_class.new(product, legacy).call).to eq(core_documents(product, legacy))
      end

      it 'matches for a bare product with no categories, options or custom fields' do
        bare = FakeCatalog::Product.new(prefixed_id: 'prod_bare', names: { 'en' => 'Bare' }, prices: { 'USD' => 1 })
        expect(described_class.new(bare, store).call).to eq(core_documents(bare, store))
      end

      it 'matches key order too, so documents serialise identically' do
        expect(documents.map(&:keys)).to eq(core_documents(product, store).map(&:keys))
      end
    end

    it 'takes categories from taxons, with ancestors, once each' do
      expect(document('en', 'USD')[:category_ids]).to eq(%w[ctg_apparel ctg_shirts ctg_sale])
      expect(document('de', 'EUR')[:category_names]).to eq(%w[Hemden Sale])
    end

    it 'takes option type and value names from presentation' do
      expect(document('en', 'USD')).to include(
        option_type_names: ['Colour (presentation)'],
        option_values: ['Red (presentation)', 'L (presentation)']
      )
    end

    it 'keeps the description as stored' do
      expect(document('en', 'USD')[:description]).to eq('<p>Breathable</p><p>Made <strong>well</strong></p>')
    end

    it 'emits preorder from 5.6.0, as core does' do
      expect(document('en', 'USD').key?(:preorder)).to eq(FakeCatalog.since?(FakeCatalog::PREORDER_SINCE))
    end

    it 'emits searchable or sortable metafields from 5.6.1, as core does, regardless of visibility' do
      expected = if FakeCatalog.since?(FakeCatalog::METAFIELD_SEARCH_SINCE)
                   { 'cf_material' => 'Cotton', 'cf_weight' => 250.0, 'cf_supplier_code' => 'SUP-1' }
                 else
                   {}
                 end
      expect(document('en', 'USD').select { |k, _| k.to_s.start_with?('cf_') }).to eq(expected)
    end

    it 'emits no collection_ids: 5.x has no collections' do
      expect(document('en', 'USD')).not_to have_key(:collection_ids)
    end

    it 'emits no positions, as core 5.x does not' do
      expect(document('en', 'USD').keys.grep(/\Apos_/)).to eq([])
    end
  end

  context 'on Spree 6.x', if: SpreeTypesense.spree_6? do
    it 'takes categories from categories (ctg_ ids), with ancestors, once each' do
      expect(document('en', 'USD')[:category_ids]).to eq(%w[ctg_apparel ctg_shirts ctg_sale])
      expect(document('de', 'EUR')[:category_names]).to eq(%w[Hemden Sale])
    end

    it 'takes option type and value names from label, not presentation' do
      expect(document('en', 'USD')).to include(option_type_names: ['Colour'], option_values: %w[Red Large])
      expect(document('de', 'EUR')).to include(option_type_names: ['Farbe'], option_values: %w[Rot Large])
    end

    it 'indexes option values from variants' do
      expect(document('en', 'USD')[:option_value_ids]).to eq(%w[optv_red optv_large])
    end

    # One token per set of two or more values one variant carries, so a
    # filter on values of several types can match a single variant (#10).
    describe 'option value combinations' do
      def option(id) = FakeCatalog::Option.new(prefixed_id: id, labels: { 'en' => id })
      def variant(*ids) = FakeCatalog::Variant.new(option_values: ids.map { |id| option(id) })

      def combinations_of(*variants)
        priced = FakeCatalog::Product.new(prefixed_id: 'prod_v', names: { 'en' => 'V' }, prices: { 'USD' => 1 },
                                          variants: variants)
        described_class.new(priced, store).call.first[:option_value_combination_ids]
      end

      it 'emits the values of each variant, sorted and joined' do
        expect(document('en', 'USD')[:option_value_combination_ids]).to eq(%w[optv_large|optv_red])
      end

      it 'never combines values that sit on different variants' do
        expect(combinations_of(variant('ov_blue', 'ov_s'), variant('ov_red', 'ov_xl'), variant('ov_blue', 'ov_xl')))
          .to contain_exactly('ov_blue|ov_s', 'ov_red|ov_xl', 'ov_blue|ov_xl')
      end

      it 'emits every set of two or more values of a variant' do
        expect(combinations_of(variant('ov_blue', 'ov_s', 'ov_new')))
          .to contain_exactly('ov_blue|ov_s', 'ov_blue|ov_new', 'ov_new|ov_s', 'ov_blue|ov_new|ov_s')
      end

      it 'emits none for variants with fewer than two values' do
        expect(combinations_of(variant('ov_blue'), variant)).to eq([])
      end
    end

    it 'emits only storefront-visible searchable or sortable custom fields' do
      expect(document('en', 'USD').select { |k, _| k.to_s.start_with?('cf_') })
        .to eq('cf_material' => 'Cotton', 'cf_weight' => 250.0)
    end

    it 'emits the description as plain text' do
      expect(document('en', 'USD')[:description]).to eq("Breathable\nMade well")
    end

    it 'emits preorder' do
      expect(document('en', 'USD')[:preorder]).to be(true)
    end

    it 'emits collection_ids from collections' do
      expect(document('en', 'USD')[:collection_ids]).to eq(%w[coll_summer coll_linen])
    end

    it 'emits the same field names as on 5.6.1, plus collection_ids and option_value_combination_ids' do
      expect(document('en', 'USD').keys.reject { |key| key.to_s.start_with?('pos_') }).to eq(
        %i[id product_id locale currency name description slug price compare_at_price status sku in_stock preorder
           store_ids channel_ids discontinue_on category_ids category_names collection_ids option_type_ids
           option_type_names option_value_ids option_value_combination_ids option_values tags units_sold_count
           available_on created_at updated_at] +
        %w[cf_material cf_weight]
      )
    end

    # The merchant's position in each collection and category, for a manual
    # listing to sort by inside Typesense (#5).
    describe 'positions' do
      def positions(document) = document.select { |key, _| key.to_s.start_with?('pos_') }

      it 'emits the position in each collection' do
        expect(positions(document('en', 'USD'))).to include('pos_coll_summer' => 3, 'pos_coll_linen' => 1)
      end

      it 'emits the position in each category and, as the lowest below it, in each ancestor' do
        expect(positions(document('en', 'USD')))
          .to include('pos_ctg_shirts' => 4, 'pos_ctg_sale' => 2, 'pos_ctg_apparel' => 2)
      end

      def positioned_in(positions)
        teas = FakeCatalog::Category.new(prefixed_id: 'ctg_teas', names: { 'en' => 'Teas' }, parent: apparel)
        green = FakeCatalog::Category.new(prefixed_id: 'ctg_green', names: { 'en' => 'Green' }, parent: teas)
        tea = FakeCatalog::Product.new(prefixed_id: 'prod_tea', names: { 'en' => 'Tea' }, prices: { 'USD' => 1 },
                                       categories: [teas, green], positions: positions)
        self.positions(described_class.new(tea, store).call.first)
      end

      it "gives an ancestor the lowest of its own and its descendants' positions" do
        expect(positioned_in('ctg_teas' => 5, 'ctg_green' => 2))
          .to eq('pos_ctg_teas' => 2, 'pos_ctg_green' => 2, 'pos_ctg_apparel' => 2)
        expect(positioned_in('ctg_teas' => 1, 'ctg_green' => 4))
          .to eq('pos_ctg_teas' => 1, 'pos_ctg_green' => 4, 'pos_ctg_apparel' => 1)
      end

      it 'emits nothing for a membership without a position' do
        expect(positioned_in({})).to eq({})
      end
    end

    it 'never reads the names 6.0 deprecated' do
      allow(product).to receive(:taxons).and_call_original
      allow(product).to receive(:variants_including_master).and_call_original
      allow(product).to receive(:metafields).and_call_original

      documents

      expect(product).not_to have_received(:taxons)
      expect(product).not_to have_received(:variants_including_master)
      expect(product).not_to have_received(:metafields)
    end

    # Outside a request Spree reads a translated attribute's base column only
    # in the application's default locale, so a store written in another
    # locale was indexed with blank names (fixed in core's own presenter in
    # Spree 6.0.5). These fakes do not model Mobility's column fallback, so
    # the examples check that the presenter names the store's locale while it
    # reads, not that a real record's names then come out.
    context "when the store's locale is not the application's" do
      let(:nl) { FakeCatalog::Market.new(currency: 'EUR', supported_locales_list: %w[nl en], default_locale: 'nl') }
      let(:dutch_store) do
        FakeCatalog::Store.new(id: 7, code: 'dutch', markets: [nl], default_market: nl,
                               supported_currencies_list: [FakeCatalog::Currency.new('EUR')])
      end
      let(:bicycle) do
        FakeCatalog::Product.new(prefixed_id: 'prod_bike', names: { 'nl' => 'Fiets', 'en' => 'Bicycle' },
                                 prices: { 'EUR' => BigDecimal('300') })
      end

      it "reads the product in the store's content locale, and restores the content locale after" do
        content_locales = []
        allow(bicycle).to receive(:name).and_wrap_original do |original, **kwargs|
          content_locales << Spree::Current.content_locale
          original.call(**kwargs)
        end
        before = Spree::Current.attributes[:content_locale]

        described_class.new(bicycle, dutch_store).call

        expect(content_locales.uniq).to eq(['nl'])
        expect(Spree::Current.attributes[:content_locale]).to eq(before)
      end

      it 'restores the content locale when a document fails to build' do
        allow(bicycle).to receive(:name).and_raise(RuntimeError, 'boom')
        before = Spree::Current.attributes[:content_locale]

        expect { described_class.new(bicycle, dutch_store).call }.to raise_error(RuntimeError, 'boom')
        expect(Spree::Current.attributes[:content_locale]).to eq(before)
      end

      context 'and no market to build documents for' do
        let(:no_markets) do
          FakeCatalog::Store.new(id: 7, code: 'dutch', markets: [], default_market: nl,
                                 supported_currencies_list: [FakeCatalog::Currency.new('EUR')])
        end

        it "indexes one document in the store's locale, read in that locale" do
          documents = described_class.new(bicycle, no_markets).call

          expect(documents.map { |d| d.values_at(:locale, :name) }).to eq([%w[nl Fiets]])
        end
      end
    end
  end

  # Whichever version is under test, its documents must import cleanly into
  # the collection Schema.definition creates — against the real server.
  describe 'indexing the documents into Typesense' do
    let(:provider) { Spree::SearchProvider::Typesense.new(store) }
    let(:collection) { provider.client.collections[provider.collection_name] }

    before do
      reset_typesense_index!(store.code)
      bootstrap_index!(provider)
    end

    it 'accepts every document and field' do
      results = provider.index_batch(documents)

      expect(results.size).to eq(3)
      expect(results).to all(include('success' => true))
    end

    it 'stores the documents as emitted, and finds them by search and category filter' do
      provider.index_batch(documents)

      stored = collection.documents['prod_shirt_en_USD'].retrieve
      expect(stored).to include('product_id' => 'prod_shirt', 'category_ids' => document('en', 'USD')[:category_ids],
                                'option_values' => document('en', 'USD')[:option_values])
      document('en', 'USD').each_key do |key|
        next if document('en', 'USD')[key].nil?

        expect(stored).to have_key(key.to_s)
      end

      found = collection.documents.search(q: 'breathable', query_by: 'description',
                                          filter_by: "category_ids:=#{category_prefix}_apparel && locale:=en")
      expect(found['hits'].map { |h| h['document']['id'] }).to contain_exactly('prod_shirt_en_USD', 'prod_shirt_en_EUR')
    end
  end
end
