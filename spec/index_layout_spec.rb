require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense::IndexLayout do
  subject(:layout) { described_class.new(typesense_client, 'shop') }

  let(:version) { 'products_shop_v1763000000000' }

  def collection_names = typesense_client.collections.retrieve.map { |c| c['name'] }
  def make(name) = typesense_client.collections.create(name: name, fields: [{ name: 'n', type: 'int32' }])

  before do
    reset_typesense_index!('shop')
    reset_typesense_index!('shop_v2')
  end

  after do
    reset_typesense_index!('shop')
    reset_typesense_index!('shop_v2')
  end

  describe 'names' do
    it 'names the live alias after the store code' do
      expect(layout.live_name).to eq('products_shop')
    end

    it 'names the build marker beside it' do
      expect(layout.building_name).to eq('products_shop__building')
    end

    it 'names a version by its millisecond timestamp' do
      expect(layout.new_version_name(1_763_000_000_000)).to eq(version)
    end

    it "matches its own versions only, not those of a store whose code extends this one's" do
      expect(layout.version_pattern).to match(version)
      expect(layout.version_pattern).not_to match('products_shop_v2_v1763000000000')
      expect(layout.version_pattern).not_to match('products_shopx_v1763000000000')
      expect(layout.version_pattern).not_to match('products_shop_v176300000000')
    end
  end

  describe '#alias_target' do
    it 'is nil when the alias does not exist' do
      expect(layout.alias_target('products_shop')).to be_nil
    end

    it 'is the collection the alias points at' do
      make(version)
      layout.point!('products_shop', version)

      expect(layout.alias_target('products_shop')).to eq(version)
    end
  end

  describe '#write_targets' do
    it 'is the live name alone when nothing is being built' do
      expect(layout.write_targets).to eq(['products_shop'])
    end

    it 'adds the collection being built' do
      make(version)
      make('products_shop_v1763000000001')
      layout.point!('products_shop', version)
      layout.point!('products_shop__building', 'products_shop_v1763000000001')

      expect(layout.write_targets).to eq(%w[products_shop products_shop_v1763000000001])
    end
  end

  describe '#legacy_collection?' do
    it 'is true for a real collection holding the live name, as 0.2.0 created' do
      make('products_shop')

      expect(layout.legacy_collection?).to be(true)
    end

    it 'is false when the live name is only an alias' do
      make(version)
      layout.point!('products_shop', version)

      expect(layout.legacy_collection?).to be(false)
    end
  end

  describe '#versioned_collections' do
    it "lists this store's versions only" do
      make(version)
      make('products_shop_v2_v1763000000000')

      expect(layout.versioned_collections).to eq([version])
    end
  end

  describe 'removal' do
    it 'drops a collection, and ignores one already gone' do
      make(version)
      layout.drop!(version)

      expect(collection_names).not_to include(version)
      expect { layout.drop!(version) }.not_to raise_error
    end

    it 'removes an alias, and ignores one already gone' do
      make(version)
      layout.point!('products_shop', version)
      layout.unpoint!('products_shop')

      expect(layout.alias_target('products_shop')).to be_nil
      expect { layout.unpoint!('products_shop') }.not_to raise_error
    end

    # A reindex removes the `__building` marker when it is done with it, but a
    # newer reindex may have taken the marker since (#22).
    describe '#release!' do
      let(:newer) { 'products_shop_v1763000999999' }

      it 'removes an alias that still points at the collection' do
        make(version)
        layout.point!('products_shop__building', version)

        expect(layout.release!('products_shop__building', version)).to be(true)
        expect(layout.alias_target('products_shop__building')).to be_nil
      end

      it 'leaves an alias that points at another collection' do
        make(version)
        make(newer)
        layout.point!('products_shop__building', newer)

        expect(layout.release!('products_shop__building', version)).to be(false)
        expect(layout.alias_target('products_shop__building')).to eq(newer)
      end

      it 'is fine with no alias' do
        expect(layout.release!('products_shop__building', version)).to be(false)
      end
    end
  end
end
