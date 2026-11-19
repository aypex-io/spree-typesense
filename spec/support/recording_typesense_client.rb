# Stands in for Typesense::Client in specs about what the provider ASKS
# Typesense: it records each search and multi_search, and answers with
# whatever the block returns, or raises what it raises. Specs about what
# Typesense DOES with a request run against the real server instead.
#
# The provider sends every search as a multi_search (a POST). #searches lists
# each search sent, whichever way. A block answering one result is taken as
# the answer to every search of a multi_search; a block answering a
# multi_search body (`'results' => [...]`) is used as it is.
#
#   client = RecordingTypesenseClient.new { |kind, params| { 'found' => 0, 'hits' => [] } }
#   allow(provider).to receive(:search_client).and_return(client)
#   provider.search_and_filter(...)
#   client.searches.first[:filter_by]
class RecordingTypesenseClient
  EMPTY_RESULT = { 'found' => 0, 'hits' => [], 'facet_counts' => [] }.freeze

  attr_reader :requests

  def initialize(&responder)
    @requests = []
    @responder = responder || ->(_kind, _params) { EMPTY_RESULT }
  end

  def collections = Hash.new { |hash, name| hash[name] = Collection.new(self, name) }

  def multi_search = MultiSearch.new(self)

  def searches
    requests.flat_map { |kind, params| kind == :multi_search ? params[:searches] : [params] }
  end

  def record(kind, params)
    requests << [kind, params]
    answer = @responder.call(kind, params)
    return answer unless kind == :multi_search && !answer.key?('results')

    { 'results' => params[:searches].map { answer } }
  end

  Collection = Struct.new(:client, :name) do
    def documents = Documents.new(client)
  end

  Documents = Struct.new(:client) do
    def search(params) = client.record(:search, params)
  end

  MultiSearch = Struct.new(:client) do
    def perform(body, _query_params = {}) = client.record(:multi_search, body)
  end
end
