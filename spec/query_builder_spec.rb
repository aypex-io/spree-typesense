require 'spec_helper'

RSpec.describe Spree::SearchProvider::Typesense::QueryBuilder do
  let(:store) { instance_double('Spree::Store', id: 7) }

  describe '.system_conditions' do
    subject(:conds) do
      described_class.system_conditions(
        store: store, locale: 'en', currency: 'USD',
        now: Time.utc(2026, 8, 2, 12, 0, 0)
      )
    end

    # Documents carry store ids as strings; quoted, so a UUID stays whole
    # and `7` cannot match as part of anything else.
    it 'scopes to the store' do
      expect(conds).to include('store_ids:=`7`')
    end

    it 'quotes a UUID store id whole' do
      uuid_store = instance_double('Spree::Store', id: '0b6c3c1e-8f3a-4c1e-9d2a-1f0e2d3c4b5a')
      out = described_class.system_conditions(store: uuid_store, locale: 'en', currency: 'USD')

      expect(out).to include('store_ids:=`0b6c3c1e-8f3a-4c1e-9d2a-1f0e2d3c4b5a`')
    end

    # THE multi-market test. Without these two, every market's copy matches.
    it 'scopes to the requested locale and currency' do
      expect(conds).to include('locale:=`en`', 'currency:=USD')
    end

    it 'quotes a hyphenated locale whole' do
      out = described_class.system_conditions(store: store, locale: 'en-US', currency: 'USD')

      expect(out).to include('locale:=`en-US`')
    end

    it 'restricts to active products' do
      expect(conds).to include('status:=active')
    end

    it 'excludes future-dated products' do
      expect(conds.join(' ')).to include('available_on_i:<=1785672000')
    end

    # Core's storefront scope, `available(now, currency, include_preorderable:
    # true)`, keeps a product scheduled to publish later when it is on
    # pre-order, so a "coming soon" launch can be pre-ordered before its date.
    it 'keeps future-dated products that are on pre-order' do
      expect(conds).to include('(available_on_i:<=1785672000 || preorder:=true)')
    end

    # 0 is the sentinel for "never discontinued"; a future discontinue_on
    # means the product is discontinued LATER and must still be visible now.
    # This must fail against a bare `discontinue_on:=0` filter.
    it 'keeps products whose discontinue date is in the future' do
      clause = conds.find { |c| c.include?('discontinue_on') }
      expect(clause).to include('discontinue_on:=0')
      expect(clause).to include('||')
      expect(clause).to match(/discontinue_on:>\d+/)
    end

    it 'strips hostile characters out of locale and currency' do
      out = described_class.system_conditions(
        store: store, locale: "en' || x:='y", currency: 'US D||', now: Time.utc(2026, 1, 1)
      )
      # discontinue_on legitimately contains '||', so check the locale/
      # currency clauses specifically rather than the whole joined string.
      locale_and_currency = out.select { |c| c.start_with?('locale:', 'currency:') }.join(' ')
      expect(locale_and_currency).not_to include("'")
      expect(locale_and_currency).not_to include('||')
    end

    it 'strips anything that could close the quote around the locale or store id' do
      hostile_store = instance_double('Spree::Store', id: '7` || store_ids:=`8')
      out = described_class.system_conditions(store: hostile_store, locale: 'en` || locale:=`de', currency: 'USD')

      expect(out.grep(/\Alocale:/).sole).to eq('locale:=`enlocalede`')
      expect(out.grep(/\Astore_ids:/).sole).to eq('store_ids:=`7store_ids8`')
    end

    it 'upcases lowercase currency codes rather than dropping them' do
      out = described_class.system_conditions(
        store: store, locale: 'en', currency: 'usd', now: Time.utc(2026, 1, 1)
      )
      expect(out).to include('currency:=USD')
    end

    # Documents carry the raw ids of the channels the product is published
    # on, as strings, quoted here so a UUID's hyphens stay inside the value.
    describe 'channel' do
      def conditions(channel_id) = described_class.system_conditions(store: store, locale: 'en', currency: 'USD',
                                                                     channel_id: channel_id)

      it 'scopes to the channel when one is given' do
        expect(conditions(3)).to include('channel_ids:=`3`')
      end

      it 'quotes a UUID channel id whole' do
        expect(conditions('0b6c3c1e-8f3a-4c1e-9d2a-1f0e2d3c4b5a'))
          .to include('channel_ids:=`0b6c3c1e-8f3a-4c1e-9d2a-1f0e2d3c4b5a`')
      end

      it 'adds no channel clause without a channel' do
        expect(conditions(nil).grep(/channel_ids/)).to be_empty
      end

      it 'strips anything that could close the quote or add a clause' do
        clause = conditions("3` || channel_ids:=`4").grep(/channel_ids/).sole

        expect(clause).to eq('channel_ids:=`3channel_ids4`')
      end
    end
  end

  describe '.user_conditions' do
    it 'coerces price bounds to numbers so filter syntax cannot be injected' do
      out = described_class.user_conditions(price_gte: '10 || status:=draft')
      expect(out).to include('price:>=10.0')
      expect(out.join(' ')).not_to include('draft')
    end

    it 'maps in_stock and out_of_stock' do
      expect(described_class.user_conditions(in_stock: '1')).to include('in_stock:=true')
      expect(described_class.user_conditions(out_of_stock: '1')).to include('in_stock:=false')
      expect(described_class.user_conditions(in_stock: '0')).to be_empty
    end

    it 'filters by category using category_ids' do
      expect(described_class.user_conditions(in_category: 'tax_x')).to include('category_ids:=tax_x')
    end

    it 'drops a category id that is not a well-formed prefixed id' do
      out = described_class.user_conditions(in_category: "tax_x || category_ids:=tax_secret")
      expect(out).to be_empty
    end

    it 'ORs multiple categories together' do
      out = described_class.user_conditions(in_categories: %w[tax_a tax_b])
      expect(out.first).to eq('category_ids:=[tax_a,tax_b]')
    end

    context 'on Spree 6.x' do
      it 'filters by collection using collection_ids' do
        expect(described_class.user_conditions(in_collection: 'coll_x')).to eq(['collection_ids:=coll_x'])
      end

      it 'drops a collection id that is not a well-formed prefixed id' do
        expect(described_class.user_conditions(in_collection: 'coll_x || collection_ids:=coll_y')).to be_empty
      end
    end

    # The filters endpoint passes the category and (Spree 6) collection
    # records of a category or collection page; facets count only within it.
    describe 'the grouping records the filters endpoint passes' do
      def record(prefixed_id) = Struct.new(:prefixed_id).new(prefixed_id)

      it 'narrows to the _category' do
        expect(described_class.condition_for('_category', record('ctg_tea'))).to eq('category_ids:=ctg_tea')
      end

      it 'ignores a _category without a well-formed prefixed id' do
        expect(described_class.condition_for('_category', record('ctg_x || status:=draft'))).to be_nil
        expect(described_class.condition_for('_category', 'ctg_tea')).to be_nil
      end

      it 'narrows to the _collection' do
        expect(described_class.condition_for('_collection', record('coll_new'))).to eq('collection_ids:=coll_new')
      end
    end

    it 'ignores with_option_value_ids (handled by grouped conditions)' do
      expect(described_class.user_conditions(with_option_value_ids: %w[ov_a])).to be_empty
    end

    it 'does not raise when a price param arrives as an Array' do
      expect { described_class.user_conditions(price_gte: ['1']) }.not_to raise_error
      out = described_class.user_conditions(price_gte: ['1'])
      expect(out.first).to eq('price:>=1.0')
    end
  end

  describe '.grouped_option_conditions' do
    # OR within an option type, AND across option types — the standard
    # e-commerce faceting semantic.
    it 'ORs within a type and ANDs across types' do
      grouped = { 1 => %w[ov_red ov_blue], 2 => %w[ov_large] }
      out = described_class.grouped_option_conditions(grouped)
      expect(out).to contain_exactly('option_value_ids:=[ov_red,ov_blue]', 'option_value_ids:=ov_large')
    end
  end

  # The token a variant's option values make, shared by the presenter and the
  # query: sorted, so the selection's order cannot change it (#10).
  describe '.combination_token' do
    it 'sorts the ids and joins them with |' do
      expect(described_class.combination_token(%w[ov_b ov_a])).to eq('ov_a|ov_b')
    end
  end

  describe '.option_conditions' do
    it 'answers nothing selected with no condition, exactly' do
      expect(described_class.option_conditions({})).to eq([[], true])
    end

    it 'ORs the values of one type, exactly' do
      expect(described_class.option_conditions(1 => %w[ov_red ov_blue]))
        .to eq([['option_value_ids:=[ov_red,ov_blue]'], true])
    end

    context 'on Spree 6.x' do
      it 'asks for one variant carrying a value of each type, whatever order they were picked in' do
        expect(described_class.option_conditions(1 => %w[ov_b], 2 => %w[ov_a]))
          .to eq([['option_value_combination_ids:=[`ov_a|ov_b`]'], true])
      end

      it 'ORs every combination of the selected values' do
        conditions, exact = described_class.option_conditions(1 => %w[ov_blue ov_red], 2 => %w[ov_s ov_xl])

        expect(conditions).to eq(['option_value_combination_ids:=[`ov_blue|ov_s`,`ov_blue|ov_xl`,`ov_red|ov_s`,`ov_red|ov_xl`]'])
        expect(exact).to be(true)
      end

      it 'drops ids that are not well-formed before combining' do
        expect(described_class.option_conditions(1 => ['ov_a', 'ov_x`] || x'], 2 => %w[ov_b]))
          .to eq([['option_value_combination_ids:=[`ov_a|ov_b`]'], true])
      end

      it 'falls back to the per-type pre-filter, inexactly, beyond six types' do
        grouped = (1..7).to_h { |type| [type, ["ov_#{type}"]] }
        conditions, exact = described_class.option_conditions(grouped)

        expect(conditions).to eq(described_class.grouped_option_conditions(grouped))
        expect(exact).to be(false)
      end

      it 'falls back to the per-type pre-filter, inexactly, beyond 1000 combinations' do
        grouped = { 1 => (1..40).map { |i| "ov_c#{i}" }, 2 => (1..30).map { |i| "ov_s#{i}" } }
        conditions, exact = described_class.option_conditions(grouped)

        expect(conditions).to eq(described_class.grouped_option_conditions(grouped))
        expect(exact).to be(false)
      end
    end
  end

  describe '.sort_by' do
    it 'maps the supported sort params' do
      expect(described_class.sort_by('price')).to eq('price:asc')
      expect(described_class.sort_by('-price')).to eq('price:desc')
      expect(described_class.sort_by('name')).to eq('name:asc')
      expect(described_class.sort_by('-available_on')).to eq('available_on:desc')
      expect(described_class.sort_by('best_selling')).to eq('units_sold_count:desc')
    end

    it 'returns nil for blank or unknown sorts so Typesense uses its default' do
      expect(described_class.sort_by(nil)).to be_nil
      expect(described_class.sort_by('nonsense')).to be_nil
    end
  end
end
