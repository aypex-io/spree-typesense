module Spree
  module SearchProvider
    class Typesense < Base
      # Typesense rejected some documents of an import, which it reports per
      # document rather than as an HTTP error.
      class ImportError < StandardError
        # The message names this many ids; #failures keeps them all.
        MAX_IDS_IN_MESSAGE = 50

        # @return [Array<Hash>] `{ id:, error: }` per rejected document
        attr_reader :failures

        # @param collection_name [String]
        # @param failures [Array<Hash>] `{ id:, error: }` per rejected document
        def initialize(collection_name, failures)
          @failures = failures
          ids = failures.map { |f| f[:id] }
          shown = ids.first(MAX_IDS_IN_MESSAGE).join(', ')
          more = ids.size > MAX_IDS_IN_MESSAGE ? " and #{ids.size - MAX_IDS_IN_MESSAGE} more" : ''
          super("#{ids.size} #{ids.size == 1 ? 'document' : 'documents'} rejected by Typesense " \
                "collection '#{collection_name}': #{shown}#{more}")
        end
      end

      # A search Typesense answered with an error body instead of an HTTP
      # error, as multi_search does per search.
      class SearchError < ::Typesense::Error; end

      # A search multi_search answered with a 429: Typesense is rate limiting.
      # A 429 to the request itself arrives as the client's HTTPError instead;
      # see #transient?.
      class RateLimited < SearchError; end

      # Raised by #reindex when a newer reindex took the `__building` marker
      # from it and then stopped without going live: it failed, or someone
      # removed the marker. The collection this reindex built has missed the
      # single-product writes made meanwhile, so it is dropped rather than
      # swapped in (#22).
      class ReindexOverlapError < StandardError
        # @param building [String] the collection this reindex built
        def initialize(building)
          super("a newer reindex took over while this one was building '#{building}', then stopped without " \
                'going live; that collection missed the product writes made meanwhile, so it was dropped and ' \
                'the live index left as it was: run the reindex again')
        end
      end

      # The network errors typesense-ruby 5.0's ApiCall retries on and, once
      # its retries are spent, raises as they are.
      NETWORK_ERRORS = [
        Errno::EINVAL, Errno::ENETDOWN, Errno::ENETUNREACH, Errno::ENETRESET, Errno::ECONNABORTED,
        Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ECONNREFUSED, Errno::EHOSTDOWN, Errno::EHOSTUNREACH
      ].freeze

      # What the Typesense client raises when it cannot answer: its own errors
      # (HTTP 4xx/5xx, timeouts, missing configuration, SearchError), Faraday's,
      # the network errors above, and a response body that is not JSON. The
      # public search entry points answer from the Database provider on any of
      # these. The base class is ::Typesense::Error; there is no
      # ::Typesense::Error::Error.
      UNAVAILABLE_ERRORS = [::Typesense::Error, Faraday::Error, *NETWORK_ERRORS, JSON::ParserError].freeze

      # The failures that pass by themselves: timeouts, 5xx, lost connections,
      # rate limiting (with #transient?, which also knows the client's 429).
      # These count towards opening the circuit breaker and are reported as
      # warnings. The rest (a rejected query from schema
      # drift, a missing collection, a bad API key, missing configuration) will
      # not pass without someone acting, and are reported as errors, so a broken
      # index does not go unnoticed while the Database provider answers.
      TRANSIENT_ERRORS = [
        ::Typesense::Error::TimeoutError, ::Typesense::Error::ServerError, ::Typesense::Error::HTTPStatus0Error,
        RateLimited, Faraday::Error, *NETWORK_ERRORS, JSON::ParserError
      ].freeze

      # Raised by #request_typesense in place of a failure in UNAVAILABLE_ERRORS,
      # so the search entry points fall back on Typesense failures only, and
      # never on an error raised around the request (the Database provider's,
      # or the authorized scope's), whatever its class.
      class Unavailable < StandardError
        attr_reader :error

        def initialize(error)
          @error = error
          super("#{error.class}: #{error.message}")
        end
      end
      private_constant :Unavailable

      # Reported once when the circuit breaker opens: Typesense has failed
      # transiently several times in a row, and searches skip it for a while.
      class CircuitOpened < StandardError; end

      # The status of a removal marker (see #mark_removed): not one of Spree's,
      # so no search, which asks for `active`, can match it.
      REMOVED_STATUS = '__removed'.freeze
      private_constant :REMOVED_STATUS

      # Set once missing configuration has been logged; see #report_unavailable.
      UNCONFIGURED_LOGGED = Concurrent::AtomicBoolean.new(false)

      # 'manual' is the merchant's own order, as the Database provider offers
      # it (Taxon/Collection::SORT_ORDERS). On Spree 6 a manually sorted
      # category or collection listing sorts by the product's position in it
      # (QueryBuilder.sort_by).
      AVAILABLE_SORT_OPTIONS = %w[manual price -price name -name -available_on available_on best_selling].freeze

      # Spree's Spree::Api::V3::ProductFilterSortOptionSerializer declares
      # `attributes :id, :label` and raises KeyError when :label is absent.
      #
      # NOTE: core also appends custom-field sort options
      # (`custom_field_schema.sort_options`). We do not yet surface those, so a
      # store using custom-field sorts will not see them under this provider.
      def sort_options_payload
        AVAILABLE_SORT_OPTIONS.map { |id| { id: id, label: nil } }
      end
      DEFAULT_SORT = 'manual'.freeze

      # Typesense defaults to 10 facet values per field and truncates silently.
      # Needed by option/category facets; the price range reads stats instead.
      MAX_FACET_VALUES = 100

      # The most searches Typesense takes in one multi_search (its default
      # `limit_multi_searches`).
      MULTI_SEARCH_LIMIT = 50

      # The most option values counted by variant per facets request: two
      # multi_searches. Values beyond it keep their count by product.
      MAX_VARIANT_COUNTS = 100

      # See #schema_client.
      SCHEMA_CHANGE_TIMEOUT_SECONDS = 120

      # See #search_client. TYPESENSE_SEARCH_TIMEOUT overrides it.
      SEARCH_TIMEOUT_SECONDS = 2

      def self.indexing_required?
        true
      end

      # Brings the collection the live name serves from up to
      # Schema.definition in place, adding the fields it lacks. With no index
      # at all it does nothing: only #reindex creates one, so a store never
      # serves an index that holds part of its catalogue without falling back.
      def ensure_index_settings!
        name = live_collection_name
        update_collection_schema!(name) if name
        nil
      end

      # Mirrors meilisearch.rb#reindex: default scope is store.products (not
      # Spree::Product.where(store_id:)), batch size 500, in primary key order,
      # lazy-preloaded associations. Returns the number of DOCUMENTS indexed
      # (not products — one product can emit N locale x currency documents).
      #
      # Builds a fresh versioned collection from Schema.definition, marked
      # `__building` while it fills so single-product writes reach it too,
      # then points the live alias at it and drops what it replaced: the
      # older versioned collections and a real collection holding the live
      # name (0.2.0's, or one a rollback to 0.2.0 created). Searches answer
      # from the previous collection until the swap, and documents of
      # products that are gone or out of scope go with the old collection.
      #
      # The scope becomes the whole index: pass every product the store
      # should find (the rake task passes store.products). To refresh some
      # products, use #index for each.
      #
      # A batch with rejected documents does not stop the reindex, and those
      # documents are not counted. Once every batch is sent, an ImportError
      # names them all, so `rake spree:search:reindex` fails visibly; the new
      # collection is then dropped and the live alias left where it was, so
      # no product goes missing from search. Any other error does the same.
      #
      # Reindexes can overlap (a manual rake run during the deploy hook's).
      # The one that started last holds the marker, so only it receives
      # single-product writes from then on, and only it goes live: an older
      # one that finds the marker taken when it ends, or fails, drops its
      # collection and returns 0, leaving the newer one to swap in (#22). If
      # the newer one has instead stopped without going live, the older one
      # has still missed those writes: it drops its collection and raises
      # ReindexOverlapError.
      def reindex(scope = nil)
        scope ||= store.products
        layout = index_layout
        building = layout.new_version_name(current_time_ms)
        client.collections.create(Schema.definition(building))
        layout.point!(layout.building_name, building)

        begin
          indexed, failures = index_scope(scope, into: building)
        rescue StandardError => e
          return give_way(layout, building, e) if marker_state(layout, building) == :superseded

          abandon_build(layout, building)
          raise
        end
        case marker_state(layout, building)
        when :superseded then return give_way(layout, building)
        when :lost
          abandon_build(layout, building)
          raise ReindexOverlapError, building
        end

        Rails.logger.info do
          "[spree_typesense] reindex complete: #{indexed} documents indexed, #{failures.size} failed"
        end
        if failures.any?
          abandon_build(layout, building)
          raise ImportError.new(building, failures)
        end

        swap_live_alias(layout, building)
        indexed
      end

      # Upserts the product's documents, then deletes those of its documents
      # it no longer produces: one product is a document per locale x currency,
      # and a product that lost a currency's price, say, must not stay
      # searchable in that market. A product that produces none loses them all.
      #
      # Every document is stamped `indexed_at` with the moment the product was
      # read, and only documents stamped earlier are deleted, so when two jobs
      # for one product overlap, the older one finishing last cannot drop what
      # the newer one wrote (#9).
      #
      # Writes to the live collection and, while a reindex is filling one, to
      # that one too, so the change survives the swap. A collection being
      # built that has since gone (its reindex died) is skipped. A product
      # producing no documents leaves a removal marker in the collection being
      # built (see #mark_removed).
      #
      # Raises ImportError (after the deletion) when Typesense rejects a
      # document, so the index job retries it.
      def index(product)
        read_at = current_time_ms
        documents = Array(presenter_class.new(product, store).call)

        results = nil
        rejected = nil
        each_write_target do |target, live|
          begin
            batch_results = index_batch(documents, into: target, indexed_at: read_at)
            results = batch_results if live
          rescue ImportError => e
            rejected ||= e
          end
          kept = documents.empty? && !live ? mark_removed(product.prefixed_id, into: target, removed_at: read_at) : documents
          remove_stale_documents(product.prefixed_id, kept, from: target, written_before: read_at)
        end
        raise rejected if rejected

        results
      end

      # Typesense answers an import with HTTP 200 and one result per document,
      # in order, so a rejected document raises nothing by itself. Each
      # rejection is logged with its document id, and once the whole batch is
      # sent an ImportError names them all.
      #
      # @param documents [Array<Hash>]
      # @param into [String] the collection or alias to import into
      # @param indexed_at [Integer] when the products were read, epoch ms
      # @return [Array<Hash>, nil] Typesense's per-document results
      # @raise [ImportError] when Typesense rejected any document
      def index_batch(documents, into: collection_name, indexed_at: current_time_ms)
        return if documents.blank?

        documents = documents.map { |d| derive_fields(d, indexed_at) }
        results = client.collections[into].documents.import(documents, action: 'upsert')

        failures = import_failures(documents, results, into)
        raise ImportError.new(into, failures) if failures.any?

        results
      end

      def remove(product)
        remove_by_id(product.prefixed_id)
      end

      # Public entry point. Answers from Typesense, or from the Database
      # provider when Typesense cannot answer: unreachable, timed out, a 5xx,
      # a rejected query (a 400 from a field the collection lacks, a missing
      # collection), or not configured. Correct results, more slowly, beat
      # an empty page. Only the Typesense request is covered: errors raised
      # around it, by the Database provider or the authorized scope, still
      # raise, as do errors that are not Typesense failing.
      def search_and_filter(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
        fallback = lambda do
          fallback_provider.search_and_filter(
            scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit
          )
        end
        return answer_from_database(filters, fallback) if answered_by_database?(filters)

        answer_through_breaker(query, fallback) do
          search_with_typesense(scope: scope, query: query, filters: filters, sort: sort, page: page, limit: limit)
        end
      end

      # Raises Unavailable when Typesense cannot answer; #search_and_filter
      # falls back. The intersection with the authorized scope runs outside
      # #request_typesense, so its errors are never taken for Typesense's.
      def search_with_typesense(scope:, query: nil, filters: {}, sort: nil, page: 1, limit: 25)
        page  = [page.to_i, 1].max
        limit = limit.to_i.clamp(1, 100)

        base, grouped = build_conditions(filters)
        option_conditions, exact = QueryBuilder.option_conditions(grouped)
        result = request_typesense do
          execute_search(query: query, conditions: base + option_conditions, sort: sort, page: page, limit: limit,
                         filters: filters)
        end

        product_ids = result['hits'].map { |h| h['document']['product_id'] }.uniq
        raw_ids = product_ids.filter_map { |pid| Spree::Product.decode_prefixed_id(pid) }

        # Values of two or more option types must sit on ONE variant, as core's
        # `Product.with_option_value_ids` decides. Documents carry combination
        # tokens that answer it exactly. Where they cannot (more types than the
        # tokens cover), the index only pre-filters and core's scope gives the
        # exact answer, so a page can come back short of `limit` and the total
        # over-count.
        scope = scope.with_option_value_ids(grouped.values.flatten) unless exact

        # SECURITY: intersect with the authorized scope, preserving engine order.
        products = if raw_ids.any?
                     records = scope.where(id: raw_ids).reorder(nil).index_by(&:id)
                     raw_ids.filter_map { |id| records[id] }
                   else
                     scope.none
                   end

        SearchResult.new(products: products, total_count: result['found'] || 0,
                          pagy: build_pagy(result['found'] || 0, page, limit))
      end

      # Facets from Typesense, or, when Typesense cannot answer, from the
      # Database provider, which computes the same ones from the database.
      # As in #search_and_filter, only the Typesense requests are covered.
      def filters(scope:, query: nil, filters: {})
        fallback = -> { fallback_provider.filters(scope: scope, query: query, filters: filters) }
        return answer_from_database(filters, fallback) if answered_by_database?(filters)

        answer_through_breaker(query, fallback) do
          result, distribution, stats = execute_faceted_search(query: query, filters: filters)

          FiltersResult.new(
            filters: Facets.build(distribution, currency: currency, stats: stats),
            sort_options: sort_options_payload,
            default_sort: default_sort_for(filters),
            total_count: result['found'] || 0
          )
        end
      end

      # Composite ids mean one product maps to N documents (locale × currency),
      # so delete by filter on product_id rather than by document id. From the
      # live collection and any collection a reindex is filling, where a
      # removal marker is left in their place (see #mark_removed).
      def remove_by_id(prefixed_id)
        removed_at = current_time_ms
        each_write_target do |target, live|
          kept = live ? [] : mark_removed(prefixed_id, into: target, removed_at: removed_at)
          remove_stale_documents(prefixed_id, kept, from: target)
        end
        nil
      end

      # The client indexing and removal go through: background jobs, which can
      # afford to wait, and retry once on a node that fails.
      def client
        @client ||= build_client(connection_timeout_seconds: 5)
      end

      # The client searches and facets go through. A shopper waits on these,
      # so a hung node must not hold the request: a short timeout and no retry
      # (the indexing client's 5s and one retry cost about 10s), after which
      # the search is answered by the Database provider. The timeout is
      # TYPESENSE_SEARCH_TIMEOUT seconds when that is a positive number.
      def search_client
        @search_client ||= build_client(connection_timeout_seconds: search_timeout_seconds, num_retries: 0)
      end

      # The live name searches and writes go through: since 0.3.0 an alias
      # over the versioned collection the last reindex built (see
      # IndexLayout).
      def collection_name
        @collection_name ||= "products_#{store.code}"
      end

      private

      # Where this store's collections and aliases live.
      def index_layout
        @index_layout ||= IndexLayout.new(client, store.code)
      end

      def current_time_ms = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)

      # The collection the live name serves from: a real collection holding
      # the name, which takes requests ahead of an alias, else the alias's
      # target. Nil when there is no index.
      def live_collection_name
        layout = index_layout
        layout.legacy_collection? ? layout.live_name : layout.alias_target(layout.live_name)
      end

      # Yields each collection a single product's write goes to, and whether
      # it is the live one. A collection being built that is gone is skipped:
      # its reindex died, and the next one replaces it.
      def each_write_target
        index_layout.write_targets.each_with_index do |target, position|
          live = position.zero?
          begin
            yield target, live
          rescue ::Typesense::Error::ObjectNotFound
            raise if live

            Rails.logger.warn { "[spree_typesense] skipped '#{target}': the collection a reindex was building is gone" }
          end
        end
      end

      # Indexes the scope in batches into `into`.
      # @return [Array(Integer, Array<Hash>)] documents accepted, and the rejected ones
      def index_scope(scope, into:)
        indexed = 0
        failures = []
        # find_in_batches walks by primary key and ignores a scoped order,
        # which Rails warns about, or rejects under error_on_ignored_order,
        # so the scope reaches it without one (#21).
        scope.unscope(:order).preload_associations_lazily.find_in_batches(batch_size: 500) do |batch|
          read_at = current_time_ms
          documents = Spree::Typesense::ProductPresenter.sharing_category_ancestors do
            batch.flat_map { |product| presenter_class.new(product, store).call }
          end
          documents = without_newer_writes(documents, into: into, read_at: read_at)
          next if documents.empty?

          accepted = documents.size
          begin
            index_batch(documents, into: into, indexed_at: read_at)
          rescue ImportError => e
            failures.concat(e.failures)
            accepted -= e.failures.size
          end
          indexed += accepted
          Rails.logger.info { "[spree_typesense] indexed #{accepted} (#{indexed} total) into #{into}" }
        end
        [indexed, failures]
      end

      # The batch's documents, less those of products a single-product write
      # (#index) has put into `into` since the batch was read (#23). That
      # write read the product later, so its documents are the newer ones:
      # importing the batch's over them would take the older ones live. A
      # write landing between this lookup and the import can still be
      # overwritten, but that window is one request, where the batch's is
      # the time it takes to build its documents.
      def without_newer_writes(documents, into:, read_at:)
        return documents if documents.empty?

        newer = product_ids_written_since(documents.map { |d| document_product_id(d) }.uniq, into: into, since: read_at)
        return documents if newer.empty?

        Rails.logger.info do
          "[spree_typesense] left out #{newer.sort.join(', ')}: saved since this batch was read, so #{into} holds newer documents"
        end
        documents.reject { |d| newer.include?(document_product_id(d)) }
      end

      # Which of the products have a document in `into` stamped `since` or
      # later: one facet search, sent as a POST, as a batch's ids are longer
      # than Typesense's GET limit allows.
      def product_ids_written_since(product_ids, into:, since:)
        quoted = product_ids.map { |id| "`#{id}`" }.join(',')
        response = client.multi_search.perform(
          { searches: [{ collection: into, q: '*', per_page: 0,
                         filter_by: "product_id:=[#{quoted}] && indexed_at:>=#{since.to_i}",
                         facet_by: 'product_id', max_facet_values: product_ids.size }] }
        )
        result = Array(response['results']).first || {}
        raise search_error_for(result) if result['error']

        (Facets.normalize(result['facet_counts'])['product_id'] || {}).keys
      end

      def document_product_id(document) = sanitize_prefixed_id(document[:product_id] || document['product_id'])

      # A product removed while a reindex is building, or saved into
      # producing no documents, leaves no document stamped `indexed_at` there
      # for #without_newer_writes to find, so a batch that read it earlier
      # would put its old documents back and take them live (#27). It leaves
      # this marker in their place: a document stamped with the removal,
      # which that check finds like any newer write, and which no search can
      # match, being in no store and in status REMOVED_STATUS. It is written
      # before the product's documents are deleted, so a batch importing in
      # between has them deleted after it. The reindex deletes the markers
      # once it is live. Returns the marker as written, or none when it could
      # not be: the deletion goes ahead either way.
      def mark_removed(prefixed_id, into:, removed_at:)
        marker = { 'id' => "#{prefixed_id}__removed", 'product_id' => prefixed_id, 'locale' => '',
                   'currency' => '', 'name' => '', 'status' => REMOVED_STATUS, 'in_stock' => false,
                   'store_ids' => [], 'discontinue_on' => 0, 'units_sold_count' => 0 }
        index_batch([marker], into: into, indexed_at: removed_at)
        [marker]
      rescue ImportError => e
        Rails.logger.warn { "[spree_typesense] could not mark #{prefixed_id} removed in #{into}: #{e.message}" }
        []
      end

      def delete_removal_markers(collection)
        client.collections[collection].documents.delete(filter_by: "status:=`#{REMOVED_STATUS}`")
      end

      # Forgets a reindex's collection: removes the marker while it is still
      # this reindex's, and drops the collection, leaving the live alias as
      # it was. Best effort, so the error that stopped the reindex is the one
      # raised.
      def abandon_build(layout, building)
        layout.release!(layout.building_name, building)
        layout.drop!(building)
      rescue StandardError => e
        Rails.logger.error { "[spree_typesense] could not clean up '#{building}': #{e.class}: #{e.message}" }
      end

      # Whose the marker is as this reindex of `building` ends:
      # - :mine while it still points at `building`
      # - :superseded when a newer reindex holds it, or has gone live (the
      #   live alias points at a newer collection) and removed it
      # - :lost when it is gone and nothing newer went live: the newer
      #   reindex failed, or someone removed the marker
      # When the marker cannot be read, the reindex goes on as its own.
      def marker_state(layout, building)
        holder = layout.alias_target(layout.building_name)
        return :mine if holder == building
        return :superseded if holder

        live = layout.alias_target(layout.live_name)
        live && layout.version_pattern.match?(live) && live > building ? :superseded : :lost
      rescue StandardError
        :mine
      end

      # A newer reindex took the marker while this one was filling
      # `building`, so `building` has missed the single-product writes made
      # since, and the newer one will swap in a collection that has them.
      # Drops `building`, leaves the live alias and the marker alone, and
      # reports nothing indexed. A failure of this reindex is logged: the
      # newer one meets it too, if it is not passing.
      def give_way(layout, building, error = nil)
        Rails.logger.warn do
          "[spree_typesense] a newer reindex took over while this one was building #{building}" \
            "#{" (and this one failed: #{error.class}: #{error.message})" if error}; " \
            "dropping #{building} and leaving #{layout.live_name} to the newer reindex"
        end
        begin
          layout.drop!(building)
        rescue StandardError => e
          Rails.logger.warn { "[spree_typesense] could not drop '#{building}' (#{e.class}: #{e.message}); the next reindex will" }
        end
        0
      end

      # Points the live alias at the collection just built, then drops what
      # it replaced. Typesense refuses an alias whose name a collection holds,
      # so a real collection holding the live name is dropped first; searches
      # in that moment get a 404 and answer from the Database provider.
      # Pointing the alias is retried once: after that drop, failing it would
      # leave the store with no index. Once it points at the new collection
      # the reindex has succeeded, so the clean-up after it only logs what it
      # could not do. Older versioned collections go, newer ones stay: a newer
      # one belongs to a reindex still running, which will drop this one when
      # it swaps.
      def swap_live_alias(layout, building)
        previous = layout.alias_target(layout.live_name)
        legacy = layout.legacy_collection?
        layout.drop!(layout.live_name) if legacy
        point_live_alias(layout, building)

        after_swap("remove the #{layout.building_name} alias") { layout.release!(layout.building_name, building) }
        after_swap('delete the removal markers') { delete_removal_markers(building) }
        replaced = after_swap('list the collections it replaced') do
          layout.versioned_collections.select { |name| name < building }
        end || []
        dropped = replaced.count { |name| after_swap("drop #{name}") { layout.drop!(name) } }

        Rails.logger.info do
          was = [(layout.live_name if legacy), previous].compact.uniq.join(', ')
          "[spree_typesense] #{layout.live_name} now serves #{building}#{" (was #{was})" unless was.empty?}; " \
            "dropped #{dropped} older collection(s)#{' and the real collection holding the live name' if legacy}"
        end
      end

      def point_live_alias(layout, building)
        attempts = 0
        begin
          layout.point!(layout.live_name, building)
        rescue StandardError => e
          attempts += 1
          raise if attempts > 1

          Rails.logger.warn { "[spree_typesense] pointing #{layout.live_name} at #{building} failed (#{e.message}); retrying" }
          retry
        end
      end

      # Clean-up once the live alias points at the new collection: the
      # reindex has succeeded, so a failure here is logged for the next
      # reindex to finish, not raised. Returns the block's value (truthy for
      # a drop), or nil when it failed.
      def after_swap(what)
        yield || true
      rescue StandardError => e
        Rails.logger.warn do
          "[spree_typesense] the swap succeeded, but could not #{what} (#{e.class}: #{e.message}); " \
            'the next reindex will'
        end
        nil
      end

      # The rejected documents of an import, logged one by one. A result names
      # its document only when the import asked for that, so fall back to the
      # position: Typesense answers one result per document, in order.
      def import_failures(documents, results, into = collection_name)
        Array(results).each_with_index.filter_map do |result, index|
          next if result['success']

          failure = { id: result['id'] || documents.dig(index, 'id'), error: result['error'] }
          Rails.logger.error do
            "[spree_typesense] Typesense rejected document #{failure[:id]} in collection " \
            "'#{into}': #{failure[:error]}"
          end
          failure
        end
      end

      # Deletes the product's documents in `from` other than `documents`; all
      # of them when `documents` is empty. With `written_before`, only
      # documents written before it go: a later job's are its own business. Ids go into
      # the filter quoted in backticks, Typesense's string literal, because
      # locales such as `en-US` put a hyphen in them. An id that itself holds a
      # backtick cannot be quoted, so nothing is deleted then rather than risk
      # deleting the wrong documents.
      def remove_stale_documents(prefixed_id, documents, from:, written_before: nil)
        kept_ids = documents.map { |d| (d[:id] || d['id']).to_s }
        return delete_product_documents(prefixed_id, from: from, written_before: written_before) if kept_ids.empty?

        if kept_ids.any? { |id| id.include?('`') }
          Rails.logger.warn { "[spree_typesense] not removing stale documents of #{prefixed_id}: an id holds a backtick" }
          return
        end

        filter = "product_id:=#{sanitize_prefixed_id(prefixed_id)} && id:!=[#{kept_ids.map { |id| "`#{id}`" }.join(',')}]"
        filter += " && indexed_at:<#{written_before.to_i}" if written_before
        client.collections[from].documents.delete(filter_by: filter)
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end

      # Nothing to remove from a collection that does not exist. With
      # `written_before`, only documents stamped earlier.
      def delete_product_documents(prefixed_id, from:, written_before: nil)
        filter = "product_id:=#{sanitize_prefixed_id(prefixed_id)}"
        filter += " && indexed_at:<#{written_before.to_i}" if written_before
        client.collections[from].documents.delete(filter_by: filter)
      rescue ::Typesense::Error::ObjectNotFound
        nil
      end

      # The Typesense request; callers wrap it in #request_typesense. Sent as
      # a one-search multi_search, a POST: a GET search carries its filter in
      # the query string, which Typesense caps at 4000 characters, and a
      # selection across option types can make a far longer filter.
      def execute_search(query:, conditions:, sort:, page:, limit:, facet_by: nil, filters: {})
        perform_searches(
          [search_params(query: query, conditions: conditions, sort: sort, page: page, limit: limit,
                         facet_by: facet_by, filters: filters)]
        ).first
      end

      # Faceted read path. Returns [main_result, distribution, stats], and
      # raises Unavailable when Typesense cannot answer.
      # `stats` always comes from the MAIN query — it covers numeric fields
      # (price), which disjunctive relaxation never touches.
      #
      # DISJUNCTIVE FACETING: with option values selected, the counts for each
      # selected option type must be computed with THAT type's own filter
      # removed — otherwise picking "Red" reports every other colour as zero
      # and the shopper can never widen their choice. That needs one extra
      # query per selected type, so it goes through multi_search. With nothing
      # selected there is nothing to relax, so we stay on the single-query path
      # rather than pay for a multi_search on every request.
      def execute_faceted_search(query:, filters:)
        base, grouped = build_conditions(filters)
        facet_by = Schema::FACET_FIELDS.join(',')

        if grouped.empty?
          result = request_typesense do
            execute_search(query: query, conditions: base, sort: nil, page: 1, limit: 0, facet_by: facet_by)
          end
          return [result, Facets.normalize(result['facet_counts']), Facets.normalize_stats(result['facet_counts'])]
        end

        option_type_ids = grouped.keys
        searches = [
          search_params(query: query, conditions: base + QueryBuilder.option_conditions(grouped).first,
                        sort: nil, page: 1, limit: 0, facet_by: facet_by)
        ]
        option_type_ids.each do |option_type_id|
          relaxed = QueryBuilder.option_conditions(grouped.except(option_type_id)).first
          searches << search_params(query: query, conditions: base + relaxed,
                                    sort: nil, page: 1, limit: 0, facet_by: 'option_value_ids')
        end

        results = request_typesense { execute_multi_search(searches) }
        type_of = option_type_of(results.flat_map { |result| option_value_counts(result).keys }.uniq)
        distribution = merge_disjunctive_facets(results.first, results.drop(1), option_type_ids, type_of)
        option_counts = request_typesense do
          count_by_variant(distribution['option_value_ids'] || {}, type_of, query: query, base: base, grouped: grouped)
        end
        [results.first, distribution.merge('option_value_ids' => option_counts),
         Facets.normalize_stats(results.first['facet_counts'])]
      end

      # The option value counts, each as the number of products choosing that
      # value would list: those with a variant carrying it together with the
      # values selected of every other option type (#19). The faceted searches
      # count a product carrying the value on any variant, so with Blue
      # selected, a product selling a Red XL beside a Blue S counted for XL.
      # A count search per value fixes that, sent in multi_searches after the
      # faceted ones, which supply the values. A lone selected type's own
      # values need none: nothing else is selected for them to sit with.
      # Neither does a selection the combination tokens cannot answer exactly
      # (see QueryBuilder.option_conditions), nor any value beyond
      # MAX_VARIANT_COUNTS: those keep the faceted count. A value no product
      # has by variant drops out, as Typesense leaves out a value it counts
      # none of.
      def count_by_variant(option_counts, type_of, query:, base:, grouped:)
        selections = option_counts.keys.filter_map { |prefixed_id|
          option_type_id = type_of[prefixed_id]
          others = grouped.except(option_type_id)
          next if option_type_id.nil? || others.empty?

          conditions, exact = QueryBuilder.option_conditions(others.merge(option_type_id => [prefixed_id]))
          [prefixed_id, conditions] if exact
        }.first(MAX_VARIANT_COUNTS)
        return option_counts if selections.empty?

        searches = selections.map do |_prefixed_id, conditions|
          search_params(query: query, conditions: base + conditions, sort: nil, page: 1, limit: 0)
        end
        found = searches.each_slice(MULTI_SEARCH_LIMIT).flat_map { |slice| execute_multi_search(slice) }
        counted = selections.map(&:first).zip(found.map { |result| result['found'].to_i }).to_h
        option_counts.merge(counted).reject { |_prefixed_id, count| count.zero? }
      end

      # The disjunctive facet searches, in one request.
      def execute_multi_search(searches) = perform_searches(searches)

      # Typesense answers multi_search with HTTP 200 even when an individual
      # search failed — the failure is a per-result {error:, code:} body, NOT an
      # exception. Raise it here as the error a search would have raised for
      # that status, so a broken filter cannot silently serve wrong results or
      # counts, and a 5xx counts as transient.
      def perform_searches(searches)
        response = search_client.multi_search.perform(
          { searches: searches.map { |s| s.merge(collection: collection_name) } }
        )
        results = response['results']

        failed = Array(results).find { |r| r['error'] }
        raise search_error_for(failed) if failed

        results
      end

      PER_RESULT_ERRORS = {
        400 => ::Typesense::Error::RequestMalformed,
        401 => ::Typesense::Error::RequestUnauthorized,
        403 => ::Typesense::Error::RequestUnauthorized,
        404 => ::Typesense::Error::ObjectNotFound,
        422 => ::Typesense::Error::ObjectUnprocessable,
        429 => RateLimited
      }.freeze
      private_constant :PER_RESULT_ERRORS

      def search_error_for(failed)
        code = failed['code'].to_i
        klass = PER_RESULT_ERRORS.fetch(code) { (500..599).cover?(code) ? ::Typesense::Error::ServerError : SearchError }
        klass.new("multi_search failed: #{failed['code']} #{failed['error']}")
      end

      # Start from the main (fully filtered) distribution, then for each option
      # type overwrite the counts of the values BELONGING TO THAT TYPE with the
      # counts from that type's own relaxed query. Values of other types keep
      # the main query's counts. `type_of` maps a value to its type (see
      # #option_type_of).
      def merge_disjunctive_facets(main_result, relaxed_results, option_type_ids, type_of)
        distribution = Facets.normalize(main_result['facet_counts'])
        merged = (distribution['option_value_ids'] || {}).dup

        per_type = {}
        relaxed_results.each_with_index do |result, i|
          per_type[option_type_ids[i]] = option_value_counts(result)
        end

        per_type.each do |option_type_id, relaxed_distribution|
          relaxed_distribution.each do |prefixed_id, count|
            merged[prefixed_id] = count if type_of[prefixed_id] == option_type_id
          end
        end

        distribution.merge('option_value_ids' => merged)
      end

      def option_value_counts(result) = Facets.normalize(result['facet_counts'])['option_value_ids'] || {}

      # { 'ov_red' => option_type_id, ... } in one query, same lookup as
      # +group_option_values_by_type+.
      def option_type_of(prefixed_ids)
        raw_ids = prefixed_ids.filter_map { |pid| Spree::OptionValue.decode_prefixed_id(pid) }
        by_raw_id = Spree::OptionValue.where(id: raw_ids).pluck(:id, :option_type_id).to_h

        prefixed_ids.each_with_object({}) do |prefixed_id, acc|
          raw_id = Spree::OptionValue.decode_prefixed_id(prefixed_id)
          acc[prefixed_id] = by_raw_id[raw_id] if raw_id
        end
      end

      # Returns [base_conditions, grouped_option_values]. Kept separate because
      # disjunctive faceting has to rebuild the option half per query while the
      # base half (system scoping + user filters) stays fixed.
      def build_conditions(filters)
        f = normalize_filters(filters)
        option_ids = f.delete('with_option_value_ids')

        base = QueryBuilder.system_conditions(store: store, locale: locale, currency: currency,
                                              channel_id: current_channel&.id)
        base += QueryBuilder.user_conditions(f)

        [base, group_option_values_by_type(Array(option_ids))]
      end

      # The channel the request is served on, read as core's storefront scope
      # and the Meilisearch provider read it on every supported version. Nil
      # outside a channel context, and then nothing is narrowed.
      def current_channel
        Spree::Current.channel
      end

      # A string-keyed copy of the filters, whichever shape they arrive in:
      # Parameters, a symbol- or string-keyed Hash, or nil.
      def normalize_filters(filters)
        f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : (filters || {}).to_h
        f.transform_keys(&:to_s)
      end

      # The sort a listing starts on, as core's FiltersAggregator derives it:
      # the collection's own sort order (categories are manual only), given in
      # the API's form ('price desc' -> '-price'), and 'manual' otherwise.
      def default_sort_for(filters)
        collection = normalize_filters(filters)['_collection']
        sort_order = collection.sort_order.presence if collection.respond_to?(:sort_order)
        field, direction = (sort_order || DEFAULT_SORT).to_s.split(' ', 2)
        direction == 'desc' ? "-#{field}" : field
      end

      def search_params(query:, conditions:, sort:, page:, limit:, facet_by: nil, filters: {})
        params = {
          q: query.presence || '*',
          query_by: Schema::SEARCHABLE_FIELDS.join(','),
          filter_by: conditions.join(' && '),
          page: page,
          per_page: limit
        }
        sort_by = QueryBuilder.sort_by(sort, normalize_filters(filters))
        params[:sort_by] = sort_by if sort_by
        if facet_by
          params[:facet_by] = facet_by
          # Typesense caps facet values at 10 per field by default and truncates
          # SILENTLY. The price range no longer depends on this (it reads
          # stats.min/max, which are exact at any cardinality), but option and
          # category facets DO — their counts only exist as returned values, and
          # string facets get no stats block. Meilisearch's equivalent default is
          # 100; match it. Residual risk: an option type with more than 100
          # values still loses its tail.
          params[:max_facet_values] = MAX_FACET_VALUES
        end
        params
      end

      # Whether the request carries a filter the index cannot apply exactly
      # (see QueryBuilder.unanswered_filters), or option values none of which
      # exists: core's `with_option_value_ids` then lists nothing, where the
      # index, with no value to filter by, would list everything.
      def answered_by_database?(filters)
        return true if QueryBuilder.unanswered_filters(filters).any?

        option_ids = QueryBuilder.present_values(normalize_filters(filters)['with_option_value_ids'])
        option_ids.any? && group_option_values_by_type(option_ids).empty?
      end

      # Spree's Database provider answers a request whose filters the index
      # cannot all apply, so a listing is never wider than asked for. That is
      # a choice, not Typesense failing: logged at info, reported nowhere, and
      # left out of the circuit breaker.
      def answer_from_database(filters, fallback)
        Rails.logger.info do
          unanswered = QueryBuilder.unanswered_filters(filters).presence || ['with_option_value_ids']
          "[spree_typesense] the index cannot apply #{unanswered.join(', ')}; answering from the Database provider"
        end
        fallback.call
      end

      # Answers through Typesense unless the circuit breaker says it is
      # failing, in which case `fallback` (the Database provider) answers at
      # once, with nothing logged. A transient failure counts towards opening
      # it, and the one that opens it is announced once; anything else
      # Typesense answered, even with an error, counts as it answering.
      # Missing configuration made no request and counts as neither. Errors
      # that are not Typesense's propagate, and free the probe if this was it.
      def answer_through_breaker(query, fallback)
        breaker = circuit_breaker
        return fallback.call unless breaker.allow_request?

        begin
          answer = yield
        rescue Unavailable => e
          record_unavailable(breaker, e.error)
          report_unavailable(e.error, query)
          return fallback.call
        rescue StandardError
          breaker.release_probe
          raise
        end

        Rails.logger.info { '[spree_typesense] Typesense is answering again' } if breaker.record_success == :closed
        answer
      end

      def record_unavailable(breaker, error)
        if error.is_a?(::Typesense::Error::MissingConfiguration)
          breaker.release_probe
        elsif transient?(error)
          announce_circuit_opened(breaker, error) if breaker.record_failure == :opened
        elsif breaker.record_success == :closed
          Rails.logger.info { '[spree_typesense] Typesense is answering again' }
        end
      end

      def announce_circuit_opened(breaker, error)
        message = "Typesense failed #{breaker.threshold} times in a row (last: #{error.class}: #{error.message}); " \
                  "skipping it for #{breaker.open_seconds.to_s.delete_suffix('.0')} seconds and answering searches " \
                  'from the Database provider'
        Rails.logger.error { "[spree_typesense] #{message}" }
        Rails.error.report(CircuitOpened.new(message), handled: true, severity: :warning,
                                                      context: { collection: collection_name })
      end

      def circuit_breaker = Spree::Typesense::CircuitBreaker.for(ENV.fetch('TYPESENSE_URL', ''))

      # Runs a Typesense request, raising Unavailable in place of any failure
      # in UNAVAILABLE_ERRORS. Wrap only the request itself: whatever the block
      # raises in that list is taken for Typesense being unavailable.
      def request_typesense
        yield
      rescue *UNAVAILABLE_ERRORS => e
        raise Unavailable, e
      end

      # Logs and reports a failure the caller is about to answer from the
      # Database provider: as a warning when it is transient, and as an error
      # when it needs someone to act (see TRANSIENT_ERRORS). Missing
      # configuration is logged and reported once per process: it fails every
      # search the same way until someone sets it.
      #
      # A manual listing of a grouping no indexed document has a position in
      # yet (before the first reindex that writes them, or a grouping with no
      # indexed product) is refused by Typesense for want of the field. That
      # is expected and needs nobody: it is logged at info, not reported, and
      # the Database provider, which sorts by position too, answers it.
      def report_unavailable(error, query)
        if error.is_a?(::Typesense::Error::MissingConfiguration)
          return unless UNCONFIGURED_LOGGED.make_true
        end
        if unindexed_position_sort?(error)
          Rails.logger.info do
            "[spree_typesense] no indexed document has a position here yet (#{error.message}); answering this " \
            'manual listing from the Database provider'
          end
          return
        end

        Rails.logger.error do
          "[spree_typesense] Typesense could not answer (#{error.class}: #{error.message}); answering from the " \
          'Database provider. If the collection is missing or out of date, run `rake spree:search:reindex`.'
        end
        severity = transient?(error) ? :warning : :error
        Rails.error.report(error, handled: true, severity: severity,
                                  context: { collection: collection_name, query: query })
      end

      # A failure in TRANSIENT_ERRORS, or the client's HTTPError for a 429:
      # typesense-ruby has no class for that status, and raises HTTPError with
      # the response for it as for any other status it has no class for.
      def transient?(error)
        TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) } || http_status(error) == 429
      end

      def http_status(error)
        return unless error.is_a?(::Typesense::Error::HTTPError) && error.data.is_a?(Hash)

        response = error.data[:response]
        response.status if response.respond_to?(:status)
      end

      def unindexed_position_sort?(error)
        error.is_a?(::Typesense::Error::ObjectNotFound) && error.message.to_s.include?('field named `pos_')
      end

      # Typesense alters a live collection in place: PATCH /collections/:name
      # with the fields to add. Documents already stored keep their values and
      # gain the new fields when next indexed. So a field a release adds
      # reaches the collection without dropping it, and the store keeps
      # serving searches throughout.
      #
      # What Typesense cannot do in place is change a field's type. Never drop
      # the collection here, which would empty a live index: name the field
      # and the remedy instead. A reindex builds a fresh collection, which has
      # the declared type.
      #
      # A failed PATCH raises, so the caller stops rather than carrying on
      # against a collection that still cannot serve the new filters.
      #
      # @param name [String] a real collection's name, not an alias
      def update_collection_schema!(name)
        live_fields = client.collections[name].retrieve['fields']

        missing = Schema.missing_fields(live_fields)
        if missing.any?
          schema_client.collections[name].update(fields: missing)
          Rails.logger.info do
            "[spree_typesense] added #{missing.map { |f| f[:name] }.join(', ')} to collection '#{name}'"
          end
        end

        Schema.type_mismatches(live_fields).each do |mismatch|
          Rails.logger.warn do
            "[spree_typesense] collection '#{name}' declares '#{mismatch[:name]}' as " \
            "#{mismatch[:live_type]}, but this release declares it #{mismatch[:type]}. Typesense cannot change " \
            "a field's type in place: reindex (`rake spree:search:reindex`), which builds a fresh collection."
          end
        end
      end

      # Schema changes block writes to the collection until Typesense finishes
      # them, and the response comes only then, so they need a far longer
      # timeout than indexing. No retries: Typesense runs one alter at a time,
      # and would refuse a retry while the first is still running.
      def schema_client
        @schema_client ||= build_client(connection_timeout_seconds: SCHEMA_CHANGE_TIMEOUT_SECONDS, num_retries: 0)
      end

      # Raises Typesense::Error::MissingConfiguration, rather than KeyError,
      # when TYPESENSE_URL or TYPESENSE_API_KEY is unset or the URL does not
      # parse, so a search treats it as Typesense being unavailable.
      def build_client(**options)
        url = ENV.fetch('TYPESENSE_URL', nil).presence
        api_key = ENV.fetch('TYPESENSE_API_KEY', nil).presence
        unless url && api_key
          missing = { 'TYPESENSE_URL' => url, 'TYPESENSE_API_KEY' => api_key }.select { |_, v| v.nil? }.keys
          raise ::Typesense::Error::MissingConfiguration, "#{missing.join(' and ')} not set"
        end

        uri = URI.parse(url)
        ::Typesense::Client.new(
          nodes: [{ host: uri.host, port: uri.port, protocol: uri.scheme }],
          api_key: api_key,
          **options
        )
      rescue URI::InvalidURIError => e
        raise ::Typesense::Error::MissingConfiguration, "TYPESENSE_URL is not a valid URL: #{e.message}"
      end

      def search_timeout_seconds
        configured = Float(ENV.fetch('TYPESENSE_SEARCH_TIMEOUT', nil), exception: false)
        configured&.positive? ? configured : SEARCH_TIMEOUT_SECONDS
      end

      # Mirrors meilisearch.rb#group_option_values_by_type. Hits the DB.
      def group_option_values_by_type(prefixed_ids)
        ids = prefixed_ids.flatten.compact.select { |id| QueryBuilder.valid_id?(id) }
        return {} if ids.empty?

        raw = ids.filter_map { |id| Spree::OptionValue.decode_prefixed_id(id) }
        Spree::OptionValue.where(id: raw).group_by(&:option_type_id)
                          .transform_values { |ovs| ovs.map(&:prefixed_id) }
      end

      # The presenter emits Spree's canonical document; Typesense needs fields
      # Spree does not provide. Derive them here rather than forking the presenter.
      def derive_fields(document, indexed_at = nil)
        doc = document.transform_keys(&:to_s)
        doc['indexed_at'] = indexed_at.to_i if indexed_at
        raw = doc['available_on']
        doc['available_on_i'] = raw.present? ? Time.parse(raw.to_s).to_i : 0
        doc
      rescue ArgumentError
        doc['available_on_i'] = 0
        doc
      end

      def build_pagy(count, page, limit)
        Pagy::Offset.new(count: count, page: page, limit: limit)
      end

      # The Database provider takes the same `audience:` as this one, and uses
      # it for its query and ransack authorisation, so a back-office search
      # (audience: nil) must not degrade into a storefront one.
      def fallback_provider
        Spree::SearchProvider::Database.new(store, audience: audience)
      end

      # The gem's own presenter, unless the application named a subclass of
      # it. Core configures none (`search_product_presenter: nil`); the engine
      # registers ours, which counts as overridden.
      #
      # The setting is shared by every installed search gem, so anything that is
      # not ours is ignored: with spree_meilisearch installed it may hold
      # Meilisearch's presenter, whose documents this schema does not describe.
      def presenter_class
        configured = Spree::Dependencies.search_product_presenter_class if Spree::Dependencies.overridden?(:search_product_presenter)
        configured.is_a?(Class) && configured <= Spree::Typesense::ProductPresenter ? configured : Spree::Typesense::ProductPresenter
      end

      # `remove_by_id` is public and reached via Spree's RemoveJob (ActiveJob
      # serialisation, not a guaranteed well-formed id), so strip anything
      # that isn't part of a legitimate prefixed id before it lands in a
      # Typesense filter expression — mirrors the Meilisearch provider's guard.
      def sanitize_prefixed_id(value)
        value.to_s.gsub(/[^a-zA-Z0-9_]/, '')
      end
    end
  end
end
