require 'spec_helper'

# Executable documentation of Typesense behaviours this gem depends on.
# These assert against the LIVE SERVER, deliberately not through our provider:
# if a Typesense upgrade changes any of them, this suite fails and tells you
# which assumption broke — before production finds out.
#
# Every example names the real defect it would have caught during the build.
RSpec.describe 'Typesense engine behaviours we rely on' do
  let(:coll) { 'behaviour_probe' }

  before do
    typesense_client.collections[coll].delete rescue nil
    typesense_client.collections.create(
      name: coll,
      default_sorting_field: 'n',
      fields: [
        { name: 'n',      type: 'int32' },
        { name: 'iso',    type: 'string', sort: true },
        { name: 'epoch',  type: 'int64' },
        { name: 'price',  type: 'float',    facet: true },
        { name: 'colour', type: 'string',   facet: true, optional: true },
        { name: 'tags',   type: 'string[]', facet: true, optional: true }
      ]
    )
  end

  after { typesense_client.collections[coll].delete rescue nil }

  def add(doc) = typesense_client.collections[coll].documents.create(doc)
  def search(params) = typesense_client.collections[coll].documents.search(params)

  # DIVERGENCE 1 — once made every search return zero results.
  # Meilisearch compares ISO8601 strings lexicographically; Typesense does not.
  # This is why the provider derives available_on_i (int64) at index time.
  describe 'range operators on string fields' do
    before { add('id' => '1', 'n' => 1, 'iso' => '2020-01-01T00:00:00Z', 'epoch' => 1_577_836_800, 'price' => 1.0) }

    it 'silently matches NOTHING on a string field, with no error raised' do
      result = search(q: '*', filter_by: 'iso:<=2026-08-02T00:00:00Z')
      expect(result['found']).to eq(0)
    end

    it 'works correctly on an int64 field' do
      result = search(q: '*', filter_by: 'epoch:<=1900000000')
      expect(result['found']).to eq(1)
    end
  end

  # DIVERGENCE 2 — once broke the price facet,
  # which derived min/max from facet KEYS.
  describe 'facet value truncation' do
    before { 15.times { |i| add('id' => i.to_s, 'n' => i, 'iso' => '2020-01-01T00:00:00Z', 'epoch' => 1, 'price' => (i + 1) * 7.5) } }

    it 'caps facet values at 10 by default and truncates silently' do
      facet = search(q: '*', facet_by: 'price')['facet_counts'].first
      expect(facet['counts'].length).to eq(10)
    end

    it 'returns more when max_facet_values is raised' do
      facet = search(q: '*', facet_by: 'price', max_facet_values: 100)['facet_counts'].first
      expect(facet['counts'].length).to eq(15)
    end

    # This is the escape hatch the price facet now uses.
    it 'reports EXACT min/max in stats even while counts are truncated' do
      facet = search(q: '*', facet_by: 'price')['facet_counts'].first
      expect(facet['stats']['min']).to eq(7.5)
      expect(facet['stats']['max']).to eq(112.5)
    end

    it 'narrows stats to the filtered set, so the price slider still tracks filters' do
      facet = search(q: '*', facet_by: 'price', filter_by: 'price:>=50')['facet_counts'].first
      expect(facet['stats']['min']).to be >= 50
    end

    # Why max_facet_values is still needed for string facets.
    it 'gives NON-numeric facets a stats block with no min/max' do
      facet = search(q: '*', facet_by: 'tags')['facet_counts'].first
      expect(facet['stats']).not_to have_key('min')
    end
  end

  # DIVERGENCE 3 — the disjunctive merge must cope with ABSENT, not zero.
  # Meilisearch reports a filtered-out value as 0; Typesense omits it.
  describe 'zero-count facet values' do
    before do
      add('id' => '1', 'n' => 1, 'iso' => 'x', 'epoch' => 1, 'price' => 1.0, 'colour' => 'red')
      add('id' => '2', 'n' => 2, 'iso' => 'x', 'epoch' => 1, 'price' => 1.0, 'colour' => 'blue')
    end

    it 'omits a filtered-out value entirely rather than reporting count 0' do
      facet = search(q: '*', facet_by: 'colour', filter_by: 'colour:=red')['facet_counts'].first
      values = facet['counts'].map { |c| c['value'] }
      expect(values).to include('red')
      expect(values).not_to include('blue')   # ABSENT, not present-with-zero
    end
  end

  # DIVERGENCE 4 — a failing sub-search does NOT raise. Missing this would have
  # silently degraded facets to empty during the original build.
  describe 'multi_search error reporting' do
    before { add('id' => '1', 'n' => 1, 'iso' => 'x', 'epoch' => 1, 'price' => 1.0) }

    it 'returns per-result error bodies instead of raising' do
      response = typesense_client.multi_search.perform(
        { searches: [
          { collection: coll, q: '*' },
          { collection: coll, q: '*', filter_by: 'nonexistent_field:=1' }
        ] }, {}
      )
      expect(response['results'][0]).not_to have_key('error')
      expect(response['results'][1]).to have_key('error')
    end
  end

  # DIVERGENCE 5 — the dead-rescue bug. `::Typesense::Error::Error` does not
  # exist, so `rescue` clauses naming it were invisible dead code and every API
  # failure escaped as NameError. Survived three task reviews.
  describe 'the client error class hierarchy' do
    it 'has NO ::Typesense::Error::Error constant' do
      expect { ::Typesense::Error::Error }.to raise_error(NameError)
    end

    it 'raises a ::Typesense::Error subclass for a missing collection' do
      expect { typesense_client.collections['definitely_missing'].documents.search(q: '*') }
        .to raise_error(::Typesense::Error)
    end
  end
end

# What 0.3.0's collection layout depends on: a full reindex builds a versioned
# collection behind the `products_<code>` alias, documents carry `pos_<id>`
# fields matched by a schema pattern, filters quote string values in
# backticks, and stale-document removal filters on `indexed_at`. Each example
# asserts what Typesense 30.2 does, so an upgrade that changes it fails here.
RSpec.describe 'Typesense engine behaviours the 0.3.0 layout relies on' do
  def ts = typesense_client
  def drop_collection(name) = (ts.collections[name].delete rescue nil)
  def drop_alias(name) = (ts.aliases[name].delete rescue nil)
  def make(name, fields = [{ name: 'n', type: 'int32' }]) = ts.collections.create(name: name, fields: fields)
  def put(collection, doc) = ts.collections[collection].documents.create(doc)
  def ids(result) = result['hits'].map { |h| h['document']['id'] }
  def collection_names = ts.collections.retrieve.map { |c| c['name'] }

  describe 'an alias' do
    before do
      drop_alias('probe_alias')
      drop_collection('probe_alias_v1')
      make('probe_alias_v1')
      ts.aliases.upsert('probe_alias', collection_name: 'probe_alias_v1')
    end

    after do
      drop_alias('probe_alias')
      drop_collection('probe_alias_v1')
    end

    it 'takes document imports, searches and deletes by filter in its target' do
      ts.collections['probe_alias'].documents.import([{ 'id' => 'a', 'n' => 1 }, { 'id' => 'b', 'n' => 2 }],
                                                    action: 'upsert')
      ts.collections['probe_alias'].documents.delete(filter_by: 'n:=1')

      expect(ids(ts.collections['probe_alias_v1'].documents.search(q: '*'))).to eq(['b'])
      expect(ids(ts.collections['probe_alias'].documents.search(q: '*'))).to eq(['b'])
    end

    it 'takes a multi_search addressed to it' do
      put('probe_alias_v1', 'id' => 'a', 'n' => 1)
      response = ts.multi_search.perform({ searches: [{ collection: 'probe_alias', q: '*' }] }, {})

      expect(response['results'].first['found']).to eq(1)
    end

    it 'reports its target when retrieved' do
      expect(ts.aliases['probe_alias'].retrieve['collection_name']).to eq('probe_alias_v1')
    end

    it 'leaves a 404 behind once its target is dropped' do
      drop_collection('probe_alias_v1')

      expect { ts.collections['probe_alias'].documents.search(q: '*') }
        .to raise_error(Typesense::Error::ObjectNotFound)
    end
  end

  # How the first 0.3.0 reindex replaces 0.2.0's real `products_<code>`
  # collection with an alias of the same name. Typesense refuses an alias
  # whose name a collection holds, so the collection is dropped first and the
  # alias created straight after; searches in between fall back.
  describe 'an alias named like an existing collection' do
    before do
      drop_alias('probe_same')
      %w[probe_same probe_same_v1].each { |name| drop_collection(name) }
      make('probe_same')
      make('probe_same_v1')
      put('probe_same_v1', 'id' => 'fresh', 'n' => 1)
    end

    after do
      drop_alias('probe_same')
      %w[probe_same probe_same_v1].each { |name| drop_collection(name) }
    end

    it 'is refused while the collection exists' do
      expect { ts.aliases.upsert('probe_same', collection_name: 'probe_same_v1') }
        .to raise_error(Typesense::Error::ServerError, /conflicts with an existing collection name/)
    end

    it 'can be created once the collection is dropped, and answers from its target' do
      drop_collection('probe_same')
      ts.aliases.upsert('probe_same', collection_name: 'probe_same_v1')

      expect(ids(ts.collections['probe_same'].documents.search(q: '*'))).to eq(['fresh'])
    end
  end

  # Rolling back to 0.2.0 runs its reindex, which creates `products_<code>`
  # (Typesense allows it beside the alias) and then upserts by that name.
  describe 'creating a collection named like an existing alias' do
    before do
      drop_alias('probe_legacy')
      %w[probe_legacy probe_legacy_v1].each { |name| drop_collection(name) }
      make('probe_legacy_v1')
      ts.aliases.upsert('probe_legacy', collection_name: 'probe_legacy_v1')
    end

    after do
      drop_alias('probe_legacy')
      %w[probe_legacy probe_legacy_v1].each { |name| drop_collection(name) }
    end

    it 'is allowed, leaving both' do
      expect { make('probe_legacy') }.not_to raise_error
      expect(collection_names).to include('probe_legacy', 'probe_legacy_v1')
    end

    it 'leaves imports and searches by that name on the alias target' do
      make('probe_legacy')
      ts.collections['probe_legacy'].documents.import([{ 'id' => 'y', 'n' => 1 }], action: 'upsert')

      expect(ids(ts.collections['probe_legacy_v1'].documents.search(q: '*'))).to eq(['y'])
      expect(ids(ts.collections['probe_legacy'].documents.search(q: '*'))).to eq(['y'])
    end
  end

  describe 'a field declared by a name pattern' do
    before do
      drop_collection('probe_pos')
      make('probe_pos', [{ name: 'n', type: 'int32' },
                         { name: 'pos_.*', type: 'int32', optional: true, sort: true }])
      put('probe_pos', 'id' => 'a', 'n' => 1, 'pos_ctg_x' => 2)
      put('probe_pos', 'id' => 'b', 'n' => 2, 'pos_ctg_x' => 1)
      put('probe_pos', 'id' => 'c', 'n' => 3)
    end

    after { drop_collection('probe_pos') }

    it 'sorts by a concrete field the pattern matched' do
      result = ts.collections['probe_pos'].documents.search(q: '*', filter_by: 'pos_ctg_x:>=0', sort_by: 'pos_ctg_x:asc')

      expect(ids(result)).to eq(%w[b a])
    end

    # A manual listing of a grouping no indexed document belongs to.
    it 'raises ObjectNotFound naming the field when sorting by a matching name no document has' do
      expect { ts.collections['probe_pos'].documents.search(q: '*', sort_by: 'pos_ctg_none:asc') }
        .to raise_error(Typesense::Error::ObjectNotFound, /Could not find a field named `pos_ctg_none`/)
    end
  end

  describe 'a backtick-quoted string value' do
    before do
      drop_collection('probe_quote')
      make('probe_quote', [{ name: 'n', type: 'int32' }, { name: 'combos', type: 'string[]', optional: true },
                           { name: 'locale', type: 'string', optional: true },
                           { name: 'store_ids', type: 'string[]', optional: true }])
      put('probe_quote', 'id' => 'ab', 'n' => 1, 'combos' => ['ov_a|ov_b'], 'locale' => 'en-US', 'store_ids' => ['7'])
      put('probe_quote', 'id' => 'ac', 'n' => 2, 'combos' => ['ov_a|ov_c'], 'locale' => 'en', 'store_ids' => ['17'])
    end

    after { drop_collection('probe_quote') }

    def matching(filter) = ids(ts.collections['probe_quote'].documents.search(q: '*', filter_by: filter))

    it 'matches a string[] value containing |' do
      expect(matching('combos:=[`ov_a|ov_b`]')).to eq(['ab'])
    end

    it 'matches any of several quoted values' do
      expect(matching('combos:=[`ov_a|ov_b`,`ov_a|ov_c`]')).to contain_exactly('ab', 'ac')
    end

    it 'matches a hyphenated locale exactly' do
      expect(matching('locale:=`en-US`')).to eq(['ab'])
    end

    it 'matches a store id exactly, not as a prefix' do
      expect(matching('store_ids:=`7`')).to eq(['ab'])
    end
  end

  describe 'deleting by filter on an optional int64' do
    before do
      drop_collection('probe_stamp')
      make('probe_stamp', [{ name: 'n', type: 'int32' }, { name: 'product_id', type: 'string' },
                           { name: 'indexed_at', type: 'int64', optional: true }])
      put('probe_stamp', 'id' => 'old', 'n' => 1, 'product_id' => 'p', 'indexed_at' => 1000)
      put('probe_stamp', 'id' => 'new', 'n' => 2, 'product_id' => 'p', 'indexed_at' => 2000)
      put('probe_stamp', 'id' => 'none', 'n' => 3, 'product_id' => 'p')
    end

    after { drop_collection('probe_stamp') }

    it 'deletes only documents stamped below the bound, and none without the field' do
      ts.collections['probe_stamp'].documents.delete(filter_by: 'product_id:=p && indexed_at:<1500')

      expect(ids(ts.collections['probe_stamp'].documents.search(q: '*'))).to contain_exactly('new', 'none')
    end
  end
end
