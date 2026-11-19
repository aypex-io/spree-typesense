module Spree
  module Typesense
    # Builds the Typesense documents for a product: flat, one per
    # (market × locale) the product is priced in.
    #
    # The fields follow spree_meilisearch 6.0's presenter (categories,
    # option `label`s, storefront-visible custom fields, a plain-text
    # description, `collection_ids`, `option_value_combination_ids`), as Spree
    # 6.0 core ships no presenter of its own (`search_product_presenter: nil`).
    # Where spree_meilisearch writes a membership document per grouping for
    # manual sort, documents here carry a `pos_<grouping prefixed id>` field per
    # collection and category instead.
    class ProductPresenter
      attr_reader :product, :store

      def initialize(product, store)
        @product = product
        @store = store
      end

      # Returns an array of documents — one per market × locale combination.
      # Each document has flat name, description, price fields (no dynamic suffixes).
      def call
        # Indexing runs in a job or a rake task, where nothing has named the
        # locale the base columns are written in.
        with_store_content_locale { build_documents }
      end

      private

      def build_documents
        documents = []

        market_locale_pairs.each do |market, locale|
          # Skip if product has no price in this currency
          next unless lowest_price(market.currency)

          Mobility.with_locale(locale) do
            documents << build_document(locale, market.currency, default_locale)
          end
        end

        # Fallback for stores without markets (legacy/test), read in the locale
        # it is labelled with rather than whatever locale the job runs in.
        if documents.empty?
          fallback_currency = store.default_market&.currency || store.supported_currencies_list.first&.iso_code
          if fallback_currency && lowest_price(fallback_currency)
            Mobility.with_locale(default_locale) do
              documents << build_document(default_locale, fallback_currency, default_locale)
            end
          end
        end

        documents
      end

      # Spree 6 reads a translated attribute from its base column only in
      # `Spree::Current.content_locale`, the locale the store's content is
      # written in. A request sets that to the store's locale; a job or a rake
      # task leaves it at the application's default. So for a store whose
      # default market locale is not the application's (`nl` beside `en`),
      # every name, description and slug read here would come out blank. Spree
      # 6.0.5 fixed its own presenter (spree/spree#15226) by naming the store's
      # locale with `Spree::Current.with_content_locale`; this does the same,
      # and on 6.0.0 to 6.0.4, which lack that helper, sets and restores the
      # attribute itself.
      def with_store_content_locale(&block)
        return Spree::Current.with_content_locale(default_locale, &block) if Spree::Current.respond_to?(:with_content_locale)

        previous = Spree::Current.attributes[:content_locale]
        Spree::Current.content_locale = default_locale.to_s
        begin
          yield
        ensure
          Spree::Current.content_locale = previous
        end
      end

      def build_document(locale, currency, fallback_locale)
        {
          # Composite ID: product + locale + currency
          id: "#{product.prefixed_id}_#{locale}_#{currency}",
          product_id: product.prefixed_id,
          locale: locale.to_s,
          currency: currency,
          # Translated fields — with fallback to default locale
          name: translated(product, :name, fallback_locale),
          # Indexed as plain text — HTML tag names would otherwise become
          # searchable tokens.
          description: Spree::RichTextHelper.to_plain_text(translated(product, :description, fallback_locale)),
          slug: translated(product, :slug, fallback_locale),
          # Price in this currency
          price: lowest_price(currency)&.to_f,
          compare_at_price: compare_at_price(currency)&.to_f,
          # Non-locale/currency fields
          status: product.status,
          sku: product.sku,
          in_stock: product.in_stock?,
          # True when the product has an active pre-order variant, so a
          # scheduled (future-published) launch still surfaces in search.
          preorder: product.preorder?,
          store_ids: Array(product.store_id).map(&:to_s),
          channel_ids: channel_ids_for_store,
          discontinue_on: product.discontinue_on&.to_i || 0,
          category_ids: category_ids_with_ancestors,
          category_names: product.categories.map { |c| translated(c, :name, fallback_locale) },
          collection_ids: product.collections.map(&:prefixed_id),
          option_type_ids: product.option_types.map(&:prefixed_id),
          option_type_names: product.option_types.map { |ot| translated(ot, :label, fallback_locale) },
          option_value_ids: variant_option_value_ids,
          option_value_combination_ids: variant_option_value_combination_ids,
          option_values: variant_option_values_data.map { |ov| translated(ov, :label, fallback_locale) }.uniq,
          tags: product.tag_list || [],
          units_sold_count: product.units_sold_count || 0,
          available_on: product.available_on&.iso8601,
          created_at: product.created_at&.iso8601,
          updated_at: product.updated_at&.iso8601
        }.merge(custom_field_document_attributes).merge(position_fields)
      end

      # Flat cf_* hash for searchable ∪ sortable custom fields (Meilisearch
      # docs). Storefront-visible ones only — the index is the storefront's,
      # and a value the serializer withholds has no business in a document it
      # can search.
      def custom_field_document_attributes
        @custom_field_document_attributes ||= product.custom_fields.filter_map do |custom_field|
          definition = custom_field.custom_field_definition
          next unless definition&.storefront_visible? && (definition.searchable? || definition.sortable?)

          [definition.filter_key, custom_field_index_value(custom_field, definition.field_type)]
        end.to_h
      end

      def custom_field_index_value(field, field_type)
        serialized = field.serialize_value
        case field_type
        when 'number'
          serialized.to_f
        else
          serialized.to_s
        end
      end

      # Returns all market × locale pairs for this store
      def market_locale_pairs
        @market_locale_pairs ||= store.markets.flat_map do |market|
          market.supported_locales_list.map { |locale| [market, locale] }
        end
      end

      def default_locale
        @default_locale ||= store.default_market&.default_locale || I18n.default_locale.to_s
      end

      # Read a translated attribute with fallback to default locale.
      def translated(record, attribute, fallback_locale)
        value = record.send(attribute)
        return value if value.present?

        record.send(attribute, locale: fallback_locale.to_sym)
      rescue ArgumentError
        value
      end

      def lowest_price(currency)
        @prices_cache ||= {}
        @prices_cache[currency] = product.price_in(currency)&.amount unless @prices_cache.key?(currency)
        @prices_cache[currency]
      end

      def compare_at_price(currency)
        @compare_at_cache ||= {}
        @compare_at_cache[currency] = product.compare_at_amount_in(currency) unless @compare_at_cache.key?(currency)
        @compare_at_cache[currency]
      end

      def channel_ids_for_store
        @channel_ids_for_store ||= product.product_publications
                                          .joins(:channel)
                                          .where(spree_channels: { store_id: store.id })
                                          .pluck(:channel_id)
                                          .map(&:to_s)
      end

      def category_ids_with_ancestors
        @category_ids_with_ancestors ||= product.categories.flat_map { |c|
          c.self_and_ancestors.map(&:prefixed_id)
        }.uniq
      end

      def variant_option_value_ids
        variant_option_values_data.map(&:prefixed_id).uniq
      end

      def variant_option_values_data
        @variant_option_values_data ||= product.variants.flat_map(&:option_values).uniq
      end

      # `pos_<prefixed id>` => position, for each collection the product is in,
      # and for each category it is in and every ancestor of it. A product
      # under a category AND one of its descendants takes the lowest position
      # in the subtree, as core's Database provider orders a category page
      # (`MIN(position)` over the subtree) and spree_meilisearch's
      # `category_positions` do. A membership without a position adds nothing,
      # nor does one whose collection or category is gone: Spree 6 removes a
      # deleted grouping's memberships in a later job (`destroy_async`).
      def position_fields
        @position_fields ||= collection_positions.merge(category_positions).to_h do |prefixed_id, position|
          ["pos_#{prefixed_id}", position]
        end
      end

      def collection_positions
        product.product_collections.each_with_object({}) do |membership, acc|
          collection = membership.collection
          next if collection.nil? || membership.position.nil?

          acc[collection.prefixed_id] = membership.position
        end
      end

      def category_positions
        product.product_categories.each_with_object({}) do |membership, acc|
          grouping = membership.category
          next if grouping.nil? || membership.position.nil?

          grouping.self_and_ancestors.each do |category|
            acc[category.prefixed_id] = [acc[category.prefixed_id], membership.position].compact.min
          end
        end
      end

      # One token per set of two or more option values that sit on the SAME
      # variant, as spree_meilisearch 6.0.5 writes them. `option_value_ids` is a
      # union across variants, so it cannot tell a product selling a blue XL
      # from one selling a blue S beside a red XL; a token per whole set can.
      # Sets reach MAX_COMBINATION_AXES values: the count grows exponentially,
      # and a filter across more types falls back to core's narrowing.
      def variant_option_value_combination_ids
        @variant_option_value_combination_ids ||= begin
          query_builder = Spree::SearchProvider::Typesense::QueryBuilder
          product.variants.flat_map do |variant|
            ids = variant.option_values.map(&:prefixed_id)
            (2..[ids.size, query_builder::MAX_COMBINATION_AXES].min).flat_map do |size|
              ids.combination(size).map { |set| query_builder.combination_token(set) }
            end
          end.uniq
        end
      end
    end
  end
end
