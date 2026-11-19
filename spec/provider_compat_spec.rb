require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense, 'wiring into Spree' do
  let(:store) { instance_double('Spree::Store', id: 1, code: 'compat') }

  # A fresh Dependencies per example, at core's defaults with nothing
  # overridden — as in a newly booted app — so examples cannot leak settings.
  let(:dependencies) { Spree::Core::Dependencies.new }

  before { stub_const('Spree::Dependencies', dependencies) }

  describe '.new' do
    it 'takes just a store, as SearchIndexable builds it' do
      expect(described_class.new(store).store).to eq(store)
    end

    context 'on Spree 6.x' do
      it 'defaults the audience to :store, as Base does' do
        expect(described_class.new(store).audience).to eq(:store)
      end

      it 'accepts audience: nil (back office) and audience: :store (storefront)' do
        expect(described_class.new(store, audience: nil).audience).to be_nil
        expect(described_class.new(store, audience: :store).audience).to eq(:store)
      end

      it 'passes the audience to Base, which limits custom_field_schema to it' do
        schema = instance_double(Spree::SearchProvider::CustomFieldSchema)
        allow(Spree::SearchProvider::CustomFieldSchema).to receive(:new).and_return(schema)

        expect(described_class.new(store, audience: nil).custom_field_schema).to be(schema)
        expect(described_class.new(store, audience: :store).custom_field_schema).to be(schema)
        expect(Spree::SearchProvider::CustomFieldSchema).to have_received(:new).with(store, audience: nil).ordered
        expect(Spree::SearchProvider::CustomFieldSchema).to have_received(:new).with(store, audience: :store).ordered
      end
    end
  end

  describe '#presenter_class (private)' do
    let(:provider) { described_class.new(store) }

    it "is the gem's own presenter when the application set none" do
      expect(provider.send(:presenter_class)).to be(Spree::Typesense::ProductPresenter)
    end

    it "is the application's presenter when it set one" do
      app_presenter = Class.new(Spree::Typesense::ProductPresenter)
      dependencies.search_product_presenter = app_presenter

      expect(provider.send(:presenter_class)).to be(app_presenter)
    end

    it "is the gem's own presenter after the engine registered it" do
      allow(Spree).to receive(:search_provider).and_return('Spree::SearchProvider::Typesense')
      Spree::Typesense.register_search_product_presenter!

      expect(provider.send(:presenter_class)).to be(Spree::Typesense::ProductPresenter)
    end

    # The setting is shared with any other search gem, such as
    # spree_meilisearch, whose documents this collection does not describe.
    it "is the gem's own presenter when the setting holds a presenter that is not ours" do
      other_presenter = Class.new
      dependencies.search_product_presenter = other_presenter

      expect(provider.send(:presenter_class)).to be(Spree::Typesense::ProductPresenter)
    end
  end

  describe 'Spree::Typesense.register_search_product_presenter!' do
    before { allow(Spree).to receive(:search_provider).and_return('Spree::SearchProvider::Typesense') }

    context 'on Spree 6.x' do
      it 'starts from core shipping no presenter' do
        expect(dependencies.search_product_presenter).to be_nil
      end

      it "registers the gem's presenter when the application set none" do
        Spree::Typesense.register_search_product_presenter!

        expect(dependencies.search_product_presenter).to eq('Spree::Typesense::ProductPresenter')
        expect(dependencies.search_product_presenter_class).to be(Spree::Typesense::ProductPresenter)
      end

      it 'registers it when a subclass of the Typesense provider is selected' do
        stub_const('MyApp::SearchProvider', Class.new(described_class))
        allow(Spree).to receive(:search_provider).and_return('MyApp::SearchProvider')

        Spree::Typesense.register_search_product_presenter!

        expect(dependencies.search_product_presenter).to eq('Spree::Typesense::ProductPresenter')
      end

      it "leaves the application's own presenter alone" do
        dependencies.search_product_presenter = 'MyApp::ProductPresenter'

        Spree::Typesense.register_search_product_presenter!

        expect(dependencies.search_product_presenter).to eq('MyApp::ProductPresenter')
      end

      it "leaves another search gem's registration alone" do
        dependencies.search_product_presenter = 'SpreeMeilisearch::ProductPresenter'

        Spree::Typesense.register_search_product_presenter!

        expect(dependencies.search_product_presenter).to eq('SpreeMeilisearch::ProductPresenter')
      end

      # Otherwise spree_meilisearch, registering after us, would find the
      # setting taken and index with our documents.
      it 'registers nothing when another search provider is selected' do
        allow(Spree).to receive(:search_provider).and_return('Spree::SearchProvider::Database')

        Spree::Typesense.register_search_product_presenter!

        expect(dependencies.overridden?(:search_product_presenter)).to be(false)
        expect(dependencies.search_product_presenter).to be_nil
      end
    end

  end

  # spec_helper makes every Spree deprecation raise, so the whole suite already
  # fails on one. This walks the gem's full surface in one place, and watches
  # Spree::Deprecation directly too, so the guarantee does not rest on that
  # global setting alone.
  describe 'Spree deprecations' do
    let(:provider) { described_class.new(store) }
    let(:collection) { provider.client.collections[provider.collection_name] }
    let(:shirts) do
      FakeCatalog::Category.new(id: 'shirts', prefixed_id: 'ctg_shirts', names: { 'en' => 'Shirts' }, permalink: 'shirts')
    end
    let(:product) do
      FakeCatalog::Product.new(prefixed_id: 'prod_dep', names: { 'en' => 'Deprecation-free' },
                               descriptions: { 'en' => '<p>Plain</p>' }, prices: { 'USD' => 5 },
                               categories: [shirts], store_id: 1)
    end
    let(:presenter_store) do
      FakeCatalog::Store.new(id: 1, code: 'compat',
                             markets: [FakeCatalog::Market.new(currency: 'USD', supported_locales_list: %w[en],
                                                               default_locale: 'en')],
                             default_market: nil, supported_currencies_list: [])
    end

    before do
      allow(Spree::Deprecation).to receive(:warn).and_call_original
      allow(Spree).to receive(:search_provider).and_return('Spree::SearchProvider::Typesense')
      reset_typesense_index!('compat')
      allow(provider).to receive(:locale).and_return('en')
      allow(provider).to receive(:currency).and_return('USD')
      stub_ar_lookup(Spree::Category, [shirts])
    end

    it 'are never triggered by registering, indexing, searching, filtering or faceting' do
      Spree::Typesense.register_search_product_presenter!
      bootstrap_index!(provider)
      provider.index_batch(provider.send(:presenter_class).new(product, presenter_store).call)

      result = provider.search_and_filter(scope: FakeScope.new(%w[prod_dep]), query: 'plain', sort: 'price')
      filters = provider.filters(scope: FakeScope.new(%w[prod_dep]))

      expect(result.products.map(&:prefixed_id)).to eq(%w[prod_dep])
      expect(filters.filters.find { |f| f[:id] == 'categories' }[:options].map { |o| o[:id] }).to eq(%w[ctg_shirts])
      expect(Spree::Deprecation).not_to have_received(:warn)
    end

    it 'leaves Spree::Taxon unreferenced: the suite never defines it' do
      expect(Spree.const_defined?(:Taxon, false)).to be(false)
    end
  end
end
