module Spree
  module SearchProvider
    class Typesense < Base
      module QueryBuilder
        PREFIXED_ID_PATTERN = /\A[a-z]+_[A-Za-z0-9]+\z/

        # Spree 6 documents carry one token per set of 2..6 option values one
        # variant has (option_value_combination_ids). A selection across more
        # types than that, or one making more tokens than the filter should
        # carry, falls back to the per-type pre-filter narrowed by core.
        MAX_COMBINATION_AXES = 6
        MAX_COMBINATION_TOKENS = 1000

        SORT_MAP = {
          'price'         => 'price:asc',
          '-price'        => 'price:desc',
          'name'          => 'name:asc',
          '-name'         => 'name:desc',
          'available_on'  => 'available_on:asc',
          '-available_on' => 'available_on:desc',
          'best_selling'  => 'units_sold_count:desc'
        }.freeze

        module_function

        # Always applied. Mirrors meilisearch.rb#system_filter_conditions.
        # locale/currency are NOT optional — documents are composite-keyed per
        # locale x currency, so omitting them returns every market's copy.
        #
        # `channel_id` narrows to the products published on that channel, as
        # core's storefront scope does (`for_channel`). Documents carry raw
        # store and channel ids as strings. String values go into the filter
        # in backticks, Typesense's string literal, so a UUID or a hyphenated
        # locale (`en-US`) stays one value; anything that could close the
        # quote is stripped first.
        def system_conditions(store:, locale:, currency:, channel_id: nil, now: Time.current)
          conditions = ["store_ids:=`#{store.id.to_s.gsub(/[^a-zA-Z0-9_-]/, '')}`"]
          conditions << "channel_ids:=`#{channel_id.to_s.gsub(/[^a-zA-Z0-9_-]/, '')}`" if channel_id.present?
          conditions << "status:=active"
          conditions << "locale:=`#{locale.to_s.gsub(/[^a-zA-Z_-]/, '')}`"
          conditions << "currency:=#{currency.to_s.upcase.gsub(/[^A-Z]/, '')}"
          # available_on_i, NOT available_on: Typesense silently matches zero
          # documents for range operators on string fields. A product
          # scheduled to publish later still shows while it is on pre-order,
          # as core's storefront scope (`include_preorderable: true`) and
          # Meilisearch's `OR preorder = true` keep it.
          conditions << "(available_on_i:<=#{now.to_i} || preorder:=true)"
          # 0 is the sentinel for "never discontinued"; a future timestamp
          # means discontinued LATER, so those products must still be
          # visible now. Mirrors meilisearch.rb's
          # "(discontinue_on = 0 OR discontinue_on > now)".
          conditions << "(discontinue_on:=0 || discontinue_on:>#{now.to_i})"
          conditions
        end

        # Returned by #condition_for for a filter the index answers by adding
        # nothing: the text query, which arrives as `query`; not_discontinued,
        # which the system conditions already apply; a stock flag set false;
        # option values, which #option_conditions turns into conditions.
        NO_CONDITION = :none

        # SECURITY: values here come from Store API query params. Numbers are
        # parsed, never coerced; ids are validated AND stripped; anything
        # invalid adds no condition, and #unanswered_filters names it, so the
        # Database provider answers instead.
        def user_conditions(filters)
          present_filters(filters).filter_map do |key, value|
            condition = condition_for(key, value)
            condition unless condition == NO_CONDITION
          end
        end

        # The filters among these the index cannot apply exactly: one it has
        # no translation for (`name_cont`, `search_by_name`, `cf_*`, any other
        # Ransack predicate), or a translated one whose value it would have to
        # drop or guess at (a malformed id, a price that is not a number). The
        # provider answers a request carrying any from Spree's Database
        # provider, which applies them all, rather than list more than was
        # asked for. Blank values filter nothing anywhere and are not named.
        #
        # @param filters [Hash, ActionController::Parameters, nil]
        # @return [Array<String>] their keys
        def unanswered_filters(filters)
          present_filters(filters).filter_map { |key, value| key if condition_for(key, value).nil? }
        end

        # A condition (String), NO_CONDITION, or nil when the index cannot
        # apply the filter exactly (see #unanswered_filters).
        def condition_for(key, value)
          case key
          when 'search', 'not_discontinued' then NO_CONDITION
          when 'price_gte'
            amount = number(Array(value).first)
            "price:>=#{amount}" if amount
          when 'price_lte'
            amount = number(Array(value).first)
            "price:<=#{amount}" if amount
          when 'price_between'
            low, high = Array(value).map { |bound| number(bound) }
            "price:[#{low}..#{high}]" if Array(value).size == 2 && low && high
          when 'in_stock'  then false_flag?(value) ? NO_CONDITION : 'in_stock:=true'
          when 'out_of_stock' then false_flag?(value) ? NO_CONDITION : 'in_stock:=false'
          when 'in_category', 'in_taxon'
            "category_ids:=#{sanitize_id(value)}" if valid_id?(value)
          when 'in_categories'
            ids = present_values(value)
            "category_ids:=[#{valid_ids(ids).join(',')}]" if ids.all? { |id| valid_id?(id) }
          when 'in_collection'
            "collection_ids:=#{sanitize_id(value)}" if valid_id?(value)
          when 'with_option_value_ids'
            NO_CONDITION if present_values(value).all? { |id| valid_id?(id) }
          # The records the filters endpoint passes on a category or collection
          # page, so facets and the total cover that grouping only.
          when '_category'
            grouping_condition('category_ids', value)
          when '_collection'
            grouping_condition('collection_ids', value)
          end
        end

        def grouping_condition(field, record)
          return unless record.respond_to?(:prefixed_id) && valid_id?(record.prefixed_id)

          "#{field}:=#{sanitize_id(record.prefixed_id)}"
        end

        # The token a set of option values makes, the same whichever order
        # they come in. The presenter writes these, the query asks for them.
        def combination_token(prefixed_ids) = prefixed_ids.map(&:to_s).sort.join('|')

        # The conditions a selection of option values (grouped by option type)
        # adds, and whether they answer it exactly. Values of one type are a
        # union, which the index answers. Values of several types must sit on
        # one variant (core's `with_option_value_ids`): there the condition
        # asks for any token over the cartesian product of the selected values.
        # Beyond what the tokens cover, the per-type conditions are only a
        # pre-filter.
        #
        # @param grouped [Hash{Object => Array<String>}] prefixed ids by option type
        # @return [Array(Array<String>, Boolean)] conditions, exact
        def option_conditions(grouped)
          axes = grouped.values.map { |ids| valid_ids(ids) }.reject(&:empty?)
          return [[], true] if axes.empty?

          per_type = grouped_option_conditions(grouped)
          return [per_type, true] if axes.size == 1
          return [per_type, false] if axes.size > MAX_COMBINATION_AXES
          return [per_type, false] if axes.map(&:size).reduce(:*) > MAX_COMBINATION_TOKENS

          tokens = axes.first.product(*axes.drop(1)).map { |values| combination_token(values) }.uniq
          [["option_value_combination_ids:=[#{tokens.map { |token| "`#{token}`" }.join(',')}]"], true]
        end

        # OR within an option type, AND across option types.
        def grouped_option_conditions(grouped)
          grouped.filter_map do |_type_id, prefixed_ids|
            ids = valid_ids(prefixed_ids)
            next if ids.empty?

            ids.length > 1 ? "option_value_ids:=[#{ids.join(',')}]" : "option_value_ids:=#{ids.first}"
          end
        end

        # The Typesense sort for the API's sort param. A listing of one
        # collection or category in the merchant's order ('manual', or no sort
        # there, whatever the text query, as core's Database provider decides)
        # sorts by the product's position in it; the collection wins when both
        # are given, as in core's `manual_sort_grouping`. 'manual' with no
        # single grouping keeps the default ranking.
        def sort_by(sort_param, filters = {})
          if sort_param.blank? || sort_param.to_s == 'manual'
            grouping = manual_grouping(filters)
            return "pos_#{grouping}:asc" if grouping
          end

          SORT_MAP[sort_param.to_s]
        end

        def manual_grouping(filters)
          f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : (filters || {}).to_h
          f = f.transform_keys(&:to_s)
          id = [f['in_collection'], f['in_category']].find { |value| valid_id?(value) }
          sanitize_id(id) if id
        end

        # The filters with a value: nil, '' and a list of blanks filter
        # nothing, here or in Spree's Database provider.
        def present_filters(filters)
          f = filters.respond_to?(:to_unsafe_h) ? filters.to_unsafe_h : (filters || {}).to_h
          f.transform_keys(&:to_s).reject { |_key, value| present_values(value).empty? }
        end

        def present_values(value) = Array(value).reject { |v| v.nil? || v.to_s.empty? }

        # What Ransack takes for false in a boolean scope, which it then
        # leaves unapplied.
        def false_flag?(value) = %w[0 f false off].include?(Array(value).first.to_s.downcase)

        # A finite number, or nil: '10 || status:=draft' and 'Infinity' are
        # not prices.
        def number(value)
          amount = value.is_a?(Numeric) ? value.to_f : Float(value.to_s.strip, exception: false)
          amount if amount&.finite?
        end

        def valid_id?(value)  = PREFIXED_ID_PATTERN.match?(value.to_s)
        def sanitize_id(value) = value.to_s.gsub(/[^a-zA-Z0-9_]/, '')
        def valid_ids(values)  = Array(values).filter_map { |v| sanitize_id(v) if valid_id?(v) }
      end
    end
  end
end
