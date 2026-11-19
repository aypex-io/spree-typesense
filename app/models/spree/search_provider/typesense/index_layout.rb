module Spree
  module SearchProvider
    class Typesense < Base
      # Where a store's documents live. Searches and single-product writes go
      # to the live alias, `products_<code>`; a full reindex builds a fresh
      # versioned collection, `products_<code>_v<epoch ms>`, marks it with the
      # `products_<code>__building` alias while it fills, then points the live
      # alias at it. 0.2.0 kept the documents in a real collection holding the
      # live name; that is the legacy collection the first reindex replaces.
      class IndexLayout
        attr_reader :client

        # @param client [Typesense::Client]
        # @param store_code [String]
        def initialize(client, store_code)
          @client = client
          @store_code = store_code.to_s
        end

        # @return [String] the alias searches and writes go through
        def live_name = "products_#{@store_code}"

        # @return [String] the alias naming the collection a reindex is filling
        def building_name = "#{live_name}__building"

        # @param now_ms [Integer] epoch milliseconds (13 digits)
        # @return [String]
        def new_version_name(now_ms) = "#{live_name}_v#{now_ms}"

        # Anchored, and the timestamp is exactly 13 digits, so a store whose
        # code extends this one's (`shop_v2` beside `shop`) never matches.
        # @return [Regexp]
        def version_pattern = /\A#{Regexp.escape(live_name)}_v\d{13}\z/

        # @param alias_name [String]
        # @return [String, nil] the collection the alias points at
        def alias_target(alias_name)
          client.aliases[alias_name].retrieve['collection_name']
        rescue ::Typesense::Error::ObjectNotFound
          nil
        end

        # Whether a real collection holds the live name. 0.2.0 created one,
        # and rolling back to 0.2.0 creates one beside the alias, where it
        # takes requests by that name ahead of the alias.
        # @return [Boolean]
        def legacy_collection? = collection_names.include?(live_name)

        # Where a single product's writes go: the live name, and the
        # collection being built when a reindex is under way, so the change
        # survives the swap.
        # @return [Array<String>]
        def write_targets
          building = alias_target(building_name)
          return [live_name] if building.nil? || building == alias_target(live_name)

          [live_name, building]
        end

        # @param alias_name [String]
        # @param collection_name [String]
        def point!(alias_name, collection_name)
          client.aliases.upsert(alias_name, collection_name: collection_name)
        end

        # Removes the alias; one already gone is fine.
        # @param alias_name [String]
        def unpoint!(alias_name)
          client.aliases[alias_name].delete
        rescue ::Typesense::Error::ObjectNotFound
          nil
        end

        # Removes the alias only while it points at the collection: a newer
        # reindex may have taken the `__building` marker since (#22).
        # Typesense has no compare-and-delete, so this reads, then deletes;
        # a newer reindex taking the marker between the two loses it.
        # @param alias_name [String]
        # @param collection_name [String]
        # @return [Boolean] whether the alias was removed
        def release!(alias_name, collection_name)
          return false unless alias_target(alias_name) == collection_name

          unpoint!(alias_name)
          true
        end

        # Drops the collection; one already gone is fine.
        # @param collection_name [String]
        def drop!(collection_name)
          client.collections[collection_name].delete
        rescue ::Typesense::Error::ObjectNotFound
          nil
        end

        # @return [Array<String>] this store's versioned collections
        def versioned_collections = collection_names.grep(version_pattern)

        private

        def collection_names = client.collections.retrieve.map { |collection| collection['name'] }
      end
    end
  end
end
