# Changelog

## 0.3.0 (unreleased)

- **CI tests Spree 6.0.5**, the latest release: the second Spree 6 leg moves
  from 6.0.1 to 6.0.5.
- **Fix: blank names for a store not written in the application's locale
  (Spree 6).** Indexing runs in a job or a rake task, where Spree reads
  translated base columns (name, description, slug, category and option
  names) only in the application's default locale. A store whose default
  market locale differs (`nl` beside an `en` application) was indexed with
  blank names, so its products could not be found by name. The presenter now
  reads in the store's locale, through `Spree::Current.with_content_locale` on
  Spree 6.0.5+ and by setting `Spree::Current.content_locale` itself on 6.0.0
  to 6.0.4, the same fix Spree 6.0.5 made to `spree_meilisearch`
  (spree/spree#15226). A store without markets has its one fallback document
  read in the locale it is labelled with.

  Spree 5.6 reads base columns the same way, but on 5.x the documents stay
  exactly as core's own 5.x presenter builds them, which this gem promises
  there, so 5.x is left as it was.

- **A full reindex swaps in a fresh collection** (#4). `rake
  spree:search:reindex` builds `products_<code>_v<epoch ms>`, then points the
  alias `products_<code>` at it and drops the collection it replaced, so
  documents of deleted or out-of-scope products no longer linger in totals
  and facets. Searches answer from the old collection until the swap; products
  saved during the reindex are written to both. Rejected documents, or any
  error, leave the store on the index it had. A field whose type changed now
  needs only a reindex. Only a reindex creates the index.

- **Fix: overlapping index jobs for one product no longer drop the newer
  job's documents** (#9). Each document is stamped `indexed_at`, the moment
  its job read the product, and a job deletes only stale documents stamped
  before its own read. Spree 6.0.5 runs one search job per store at a time,
  but only under Solid Queue; this holds on any queue adapter (Sidekiq
  included).

- **Fix: locale and store id are quoted in every search's filter** (#12).
  A hyphenated locale (`en-US`) and a UUID store id now reach Typesense as
  one backtick-quoted value, as channel ids already did.

- **Facets on category and collection pages count only that grouping** (#6).
  The filters endpoint passes the page's category (and, on Spree 6, its
  collection); its facets and total now cover that grouping instead of the
  whole store. Buyer-catalog narrowing is still not mirrored.
- **Spree 5.x category pages default to the category's sort order** (#11), as
  core 5.x's `FiltersAggregator` does, instead of `manual`.

- **Spree 6 multi-option filters match one variant exactly** (#10).
  Documents carry `option_value_combination_ids`, one token per set of two to
  six option values a variant has (as `spree_meilisearch` 6.0.5 writes them),
  and a filter on values of several option types asks for those tokens. Pages
  are full and totals exact; core's `with_option_value_ids` narrowing now
  applies only beyond six types or 1000 combinations, and on Spree 5.x.

### Upgrading

On Spree 6, a store whose default market locale differs from
`config.i18n.default_locale`: bump the gem and run
`bin/rake spree:search:reindex` to fill in the names. Other stores need do
nothing.

## 0.2.0 (2026-10-31)

### Spree 6.0 support

- Supports Spree 5.5 to 6.0 (`spree_core >= 5.5, < 6.1`; 0.1.x allowed
  `< 6.0`).
- Ships its own product presenter, `SpreeTypesense::ProductPresenter`, and
  indexes with it on every Spree version: Spree 6.0 core ships none. On 5.x
  its documents are the same as core's, field for field. On 6.0 the engine
  registers it as `Spree::Dependencies.search_product_presenter` when
  Typesense is the selected search provider and nothing else is registered.
- Follows Spree 6.0's renames (categories, option `label`, custom fields,
  plain-text descriptions, `variants`) without triggering its deprecations.
- `in_collection` filters on a new `collection_ids` field (Spree 6), so a
  collection listing returns, counts and facets only that collection.
  Existing collections gain the field in place on the next reindex.

### Fixes

- **Reindexing adds new fields in place.** `rake spree:search:reindex` now
  adds any field a release declares that the existing collection lacks,
  without dropping it, so searches keep answering. Before, an existing
  collection was left as it was, and `in_collection` filters against it
  failed. A field whose type changed is reported by name, with the remedy
  (drop and reindex).
- **Rejected documents are reported.** Typesense reports a rejected document
  in its import response rather than as an error, and these used to pass
  unnoticed. Each is now logged with its id and the reason; indexing a
  product raises, so the index job retries; and the reindex carries on, does
  not count them, and fails at the end naming them.
- **Stale documents are removed.** Re-indexing a product deletes the
  documents it no longer produces, such as those of a currency or locale it
  lost, so it stops showing in that market. A product that produces no
  documents loses them all.
- **Pre-orders show.** A product scheduled to publish later is listed while
  it is on pre-order, as Spree's own storefront listing does.
- **Results follow the current channel.** With a current channel, searches
  and facets count only the products published on it, so totals and pages
  match what the channel sells.
- **Default and manual sort.** The filters endpoint offers `manual`, and on a
  Spree 6 collection page reports the collection's own sort order as the
  default. On Spree 6, a category or collection listing in manual order with
  no text query is answered by the `Database` provider, which orders it by
  position.
- **Filtering by two or more option types is exact** on Spree 6: only
  products with one variant matching every selected type are listed.
- **Any Typesense failure falls back to the `Database` provider.** Before,
  only a refused connection did: a timeout, a 5xx, a rejected query (such as
  a filter on a field the collection lacks) or a missing collection returned
  an empty page or empty facets, and an unset `TYPESENSE_URL` or
  `TYPESENSE_API_KEY` raised a 500. Searches and facets now answer from the
  `Database` provider in all these cases, with the failure logged (missing
  configuration once per process) and reported through `Rails.error`: as a
  warning when transient (a timeout, a 5xx, a lost connection), and as an
  error when it needs someone to act (a rejected query, a missing collection,
  a bad API key, missing configuration).
- **Searches give up sooner on a hung node.** They use their own client with
  a 2 second timeout and no retry, rather than about 10 seconds; set
  `TYPESENSE_SEARCH_TIMEOUT` to change it. Indexing keeps its 5 second timeout
  and one retry.

### Known limitations

See [Known limitations](README.md#known-limitations) in the README:

- Manual (position) order comes from the `Database` provider, on Spree 6
  only; the index carries no positions.
- A full reindex does not remove documents of deleted products.
- Facet counts don't apply narrowing made only to the product scope, such as
  Spree 6's buyer catalogs.
- `price_between`, `in_taxon`, `search_by_name`, other ransack predicates and
  `cf_*` filters are ignored. Sorts other than price, name, availability date
  and best selling (`created_at`, `cf_*`, ...) get the default ranking, and
  `cf_*` sorts are not offered.
- On Spree 6, filtering by values of two or more option types narrows the page
  after Typesense has counted it, so a page can come back short and the total
  can over-count.

### Upgrading

1. Bump the gem and run `bin/rake spree:search:reindex`. It adds
   `collection_ids` to a collection a 0.1.x release created, in place. A
   store on Spree 5.6 can do this before moving to Spree 6.
2. When moving to Spree 6.0: upgrade Spree, run
   `bin/rake spree:migrate_taxons_to_categories_and_collections`, then
   `bin/rake spree:search:reindex` straight after.
3. `rake spree:search:reindex` now fails, naming the documents, if Typesense
   rejects any of them. On a multi-store install the stores after the failing
   one are then not reindexed: fix the documents and rerun.

See [Upgrading](README.md#upgrading) for the details, including what to do
when a field's type changes.

## 0.1.2 (2026-08-02)

- Sort options carry `label: nil`, which Spree 5.6's filters serializer
  requires; the filters endpoint no longer fails on Spree 5.6.
