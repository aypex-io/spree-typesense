require 'spec_helper'

# The Store API hands the provider every `q` predicate. Spree's Database
# provider applies them all; the index answers the ones it translates
# exactly, and the Database provider answers any request carrying another,
# so a listing is never wider than asked for. That is a choice, not Typesense
# failing: nothing is reported and the circuit breaker is left alone.
RSpec.describe Spree::SearchProvider::Typesense, 'filters the index cannot apply' do
  let(:store)    { instance_double('Spree::Store', id: 1, code: 'shop') }
  let(:scope)    { FakeScope.new([]) }
  let(:client)   { RecordingTypesenseClient.new }
  let(:database) do
    instance_double(Spree::SearchProvider::Database, search_and_filter: :database_search, filters: :database_filters)
  end
  let(:info_logged) { [] }
  let(:errors_logged) { [] }
  let(:reported) { [] }
  let(:provider) do
    described_class.new(store).tap do |p|
      allow(p).to receive_messages(locale: 'en', currency: 'USD', search_client: client)
    end
  end

  before do
    allow(Spree::SearchProvider::Database).to receive(:new).and_return(database)
    logger = Logger.new(File::NULL)
    allow(logger).to receive(:info) { |msg = nil, &blk| info_logged << (msg || blk&.call) }
    allow(logger).to receive(:error) { |msg = nil, &blk| errors_logged << (msg || blk&.call) }
    allow(Rails).to receive(:logger).and_return(logger)
    reporter = Object.new
    allow(reporter).to receive(:report) { |error, **| reported << error }
    allow(Rails).to receive(:error).and_return(reporter)
  end

  it 'answers a search from the Database provider, with the same arguments, without asking Typesense' do
    filters = { 'name_cont' => 'tea', 'in_stock' => '1' }

    result = provider.search_and_filter(scope: scope, query: 'herbal', filters: filters, sort: 'price', page: 2, limit: 5)

    expect(result).to eq(:database_search)
    expect(database).to have_received(:search_and_filter)
      .with(scope: scope, query: 'herbal', filters: filters, sort: 'price', page: 2, limit: 5)
    expect(client.requests).to be_empty
  end

  it 'answers facets from the Database provider, with the same arguments, without asking Typesense' do
    filters = { 'cf_material' => 'cotton', '_category' => nil }

    expect(provider.filters(scope: scope, query: 'herbal', filters: filters)).to eq(:database_filters)
    expect(database).to have_received(:filters).with(scope: scope, query: 'herbal', filters: filters)
    expect(client.requests).to be_empty
  end

  it 'names the filters at info, and reports nothing' do
    provider.search_and_filter(scope: scope, filters: { 'search_by_name' => 'tea', 's' => 'name asc' })

    expect(info_logged.join(' ')).to include('search_by_name', 's', 'Database')
    expect(errors_logged).to be_empty
    expect(reported).to be_empty
  end

  it 'asks Typesense when every filter is one it applies' do
    provider.search_and_filter(scope: scope, filters: { 'price_between' => %w[10 20], 'in_taxon' => 'ctg_tea',
                                                        'name_cont' => '' })

    expect(database).not_to have_received(:search_and_filter)
    expect(client.searches.sole[:filter_by]).to include('price:[10.0..20.0]', 'category_ids:=ctg_tea')
  end

  # Core's `with_option_value_ids` lists nothing when none of the values
  # exists; without any to filter by, the index would list everything.
  it 'answers from the Database provider when none of the option values given exists' do
    allow(provider).to receive(:group_option_values_by_type).and_return({})

    expect(provider.search_and_filter(scope: scope, filters: { 'with_option_value_ids' => %w[ov_gone] }))
      .to eq(:database_search)
    expect(provider.filters(scope: scope, filters: { 'with_option_value_ids' => %w[ov_gone] }))
      .to eq(:database_filters)
    expect(client.requests).to be_empty
  end

  describe 'the circuit breaker' do
    let(:now) { [1_000.0] }
    let(:breaker) { Spree::Typesense::CircuitBreaker.new(threshold: 1, open_seconds: 30, clock: -> { now.first }) }

    before { allow(Spree::Typesense::CircuitBreaker).to receive(:for).and_return(breaker) }

    it 'leaves a pending probe to the next request Typesense can answer' do
      breaker.record_failure
      now[0] += 30

      provider.search_and_filter(scope: scope, filters: { 'name_cont' => 'tea' })

      expect(breaker.state).to eq(:half_open)
      expect(breaker.allow_request?).to be(true)
    end

    it 'counts nothing towards opening' do
      2.times { provider.search_and_filter(scope: scope, filters: { 'name_cont' => 'tea' }) }

      expect(breaker.state).to eq(:closed)
    end
  end
end
