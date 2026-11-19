# spree-typesense

A [Typesense](https://typesense.org) search provider for [Spree Commerce](https://spreecommerce.org) 6
(`spree_core ~> 6.0`; tested on 6.0.0 and 6.0.5). Its major version tracks
Spree's, as the other Aypex Spree gems' do.

Spree 6 ships a `Database` search provider, and `spree_meilisearch` adds a
Meilisearch one. This gem adds a Typesense one,
implementing the same `Spree::SearchProvider::Base` contract so
nothing downstream changes: it returns Spree's own `SearchResult` and
`FiltersResult` objects, and Spree's existing indexing jobs and
`rake spree:search:reindex` work unmodified.

Motivation: Meilisearch's open-source build is single-node, with HA reserved for
its Enterprise edition. Typesense ships Raft-based clustering in open source, so
a multi-node cluster survives losing a node.

## Install

```ruby
gem 'spree-typesense', '~> 6.0'
```

Before 6.0.0 the gem was `spree_typesense`, published as git tags only, and
supported Spree 5.5 to 6.0; see [Upgrading](#upgrading).

Then select the provider by environment:

```ruby
# config/initializers/spree.rb
Spree.search_provider = 'Spree::SearchProvider::Typesense' if ENV['TYPESENSE_URL'].present?
```

Requires `TYPESENSE_URL` and `TYPESENSE_API_KEY`. `TYPESENSE_SEARCH_TIMEOUT`,
`TYPESENSE_BREAKER_THRESHOLD` and `TYPESENSE_BREAKER_SECONDS` are optional; see
[When Typesense is unavailable](#when-typesense-is-unavailable).

Then build the index: `bin/rake spree:search:reindex`.

See [CHANGELOG.md](CHANGELOG.md) for what each release changes.

## When Typesense is unavailable

Searches and filter facets answer from Spree's `Database` provider whenever
Typesense cannot answer: the connection is refused, the request times out,
Typesense returns a 5xx, or it rejects the query (a missing collection, a
filter on a field the collection lacks). On Spree 6 the `Database` provider is
built with the same `audience:`, so a back-office search stays one. Correct
results, more slowly, beat an empty page. Each failure is logged at error level
and reported through `Rails.error` as handled: as a warning when it is
transient (a timeout, a 5xx, a lost connection), and as an error when it needs
someone to act (a rejected query, a missing collection, a bad API key, missing
configuration), so a broken index does not go unnoticed.

An unset `TYPESENSE_URL` or `TYPESENSE_API_KEY` counts as unavailable too:
searches answer from the `Database` provider, and the problem is logged once
per process rather than on every search. Indexing still raises, so the jobs
fail and retry.

Searches and facets go through their own client, with a 2 second timeout and
no retry, so a hung node costs a shopper about 2 seconds before the fallback
answers. Set `TYPESENSE_SEARCH_TIMEOUT` (in seconds, e.g. `1.5`) to change it.
Indexing keeps a 5 second timeout and one retry, and Spree's index jobs retry
on failure.

During an outage each process stops trying after a while. After three
transient failures in a row (timeouts, 5xx, lost connections) it skips
Typesense for 30 seconds: searches and facets answer from the `Database`
provider at once, with nothing logged per search. Opening is logged once at
error level and reported once through `Rails.error` as a warning
(`Spree::SearchProvider::Typesense::CircuitOpened`). Then one search probes
Typesense; if it answers, searches go back to it, and if not, it waits
another 30 seconds. Errors that need someone to act (a rejected query, a
missing collection, a bad key, missing configuration) never open it.

| Variable | Default | |
|---|---|---|
| `TYPESENSE_SEARCH_TIMEOUT` | `2` | seconds a search waits for Typesense |
| `TYPESENSE_BREAKER_THRESHOLD` | `3` | transient failures in a row that open the breaker |
| `TYPESENSE_BREAKER_SECONDS` | `30` | seconds searches skip Typesense once it opens |

## Reindexing

`bin/rake spree:search:reindex` builds each store's index afresh: a new
collection, `products_<store code>_v<epoch ms>`, filled from the store's
products, then swapped in behind the alias `products_<store code>`, which is
the name searches and index jobs use. The collection it replaced is dropped,
and with it the documents of products that were deleted or left the scope.

- Searches keep answering from the previous collection until the swap.
- While a reindex runs, the collection it is filling is marked by the alias
  `products_<store code>__building`, and a product saved meanwhile is written
  to both, so the change survives the swap.
- If Typesense rejects any document, or the reindex fails, the new collection
  is dropped and the alias left where it was: the store keeps the index it
  had, and the rake task fails naming the rejected documents.
- Only a reindex creates the index. Until the first one, index jobs fail and
  retry, and searches answer from the `Database` provider.
- The scope a reindex is given becomes the whole index. `rake
  spree:search:reindex` passes every product of the store; passing fewer
  (`provider.reindex(Spree::Product.where(id: ids))`) would leave only those
  searchable. To refresh some products, index them one by one
  (`provider.index(product)`, or Spree's `product.add_to_search_index`).

## Known limitations

- **Manual (position) sort uses one field per grouping.** Each document
  carries `pos_<prefixed id>`, the product's position in each
  collection and category it belongs to (an ancestor category takes the
  lowest position below it), and a single category or collection listing in
  manual order (`sort` omitted or `manual`, with or without a text query, as
  core decides) sorts by it inside Typesense. Each grouping adds a field to
  the collection's schema, which suits catalogues with hundreds or a few
  thousand groupings. A grouping no indexed document has a position in yet
  is answered by the `Database` provider.
- **Facets don't apply buyer-catalog narrowing.** Facet counts come from the
  index and the filters given. A category or collection page's own grouping is
  applied (the filters endpoint passes it), but narrowing made only to the
  product `scope`, such as Spree 6's buyer catalogs and audiences, is not:
  the index cannot express it. Spree's Meilisearch provider has the same
  limit. Search results are always intersected with the scope.
- **Some filters and sorts are ignored.** The index answers `price_gte`,
  `price_lte`, `in_stock`, `out_of_stock`, `in_category`, `in_categories`,
  `in_collection` (Spree 6) and `with_option_value_ids`. It ignores
  `price_between`, `in_taxon`, `search_by_name`, other ransack predicates such
  as `name_cont`, and `cf_*` custom-field filters. It sorts by `price`,
  `-price`, `name`, `-name`, `available_on`, `-available_on` and
  `best_selling`; any other sort, such as `created_at` or a `cf_*` sort, gets
  the default ranking. `cf_*` sorts are not offered.
- **Option facet counts are per product.** With values of one option type
  selected, the counts for another type's values count products that carry
  the value on any variant: with Blue selected, XL counts a product selling a
  Red XL beside a Blue S, though choosing XL then lists only products with a
  Blue XL. The listing and its total are exact; only the counts beside the
  values can run higher. Spree's Meilisearch provider counts the same way.
- **Values of more than six option types at once.** Values of
  two to six option types must sit on one variant, and the index answers that
  exactly through one token per set of a variant's values. Beyond six types
  (or 1000 combinations of the selected values) the index only pre-filters by
  each type and core's `Product.with_option_value_ids` narrows the scope, so a
  page can come back shorter than `limit` and the total can over-count.

## Engine behaviours this gem depends on

Typesense and Meilisearch diverge in several ways that fail **silently** — no
error, just wrong answers. Those behaviours are pinned as executable specs in
`spec/typesense_behaviour_spec.rb`, which doubles as an upgrade canary: run it
first when bumping the Typesense version.

### Documents

The gem builds its documents with its own `Spree::Typesense::ProductPresenter`,
following `spree_meilisearch`'s presenter. Spree 6 core ships no search
presenter (`search_product_presenter: nil`); at boot the engine registers this
one as `Spree::Dependencies.search_product_presenter`, unless the application
or another search gem already set one, and only when Typesense is the selected
`Spree.search_provider`, so with `spree_meilisearch` installed alongside, each
gem's presenter goes with its own provider.

An application can set `Spree::Dependencies.search_product_presenter` to a
subclass of `Spree::Typesense::ProductPresenter`, and the provider indexes with
it. Any other presenter there is ignored and the gem's own is used: the setting
is shared by every installed search gem, and another gem's documents
(`spree_meilisearch`'s, say) do not fit this collection's schema.

- **Categories:** `category_ids` (with every ancestor) and `category_names`
  come from `product.categories`; the category facet looks up
  `Spree::Category`. The gem never references the deprecated `Spree::Taxon`.
- **Options:** `option_type_names` and `option_values` read `label`; option
  values come from `product.variants`.
- **Custom fields:** `cf_*` keys come from `product.custom_fields`, for
  definitions that are storefront-visible and marked searchable or sortable.
  They are stored but not declared in the schema, so Typesense does not index
  them: they cannot be searched, filtered or sorted on.
- **Collections:** documents carry `collection_ids`, and `in_collection`
  filters on it, so a collection listing returns, counts and facets only that
  collection.
- **Descriptions** are indexed as plain text
  (`Spree::RichTextHelper.to_plain_text`), so tag names are not searchable.
- **Base columns are read in the store's content locale.** Spree 6 reads a
  translated attribute's base column only in `Spree::Current.content_locale`,
  which a job or rake task leaves at the application's default locale. The
  presenter sets it to the store's default market locale while it builds, as
  `spree_meilisearch` does from 6.0.5. Without this, a store whose locale is
  not the application's (`nl` beside `en`) would index blank names.
- **Providers take an `audience:`** (`:store` by default, `nil` for the back
  office). The gem inherits `Base#initialize`, so `custom_field_schema` is
  limited to what that audience may see. When Typesense cannot answer, the
  Database fallback is built with the same audience, so a back-office search
  does not degrade into a storefront one.

Loading and using the gem triggers no Spree deprecation warning; the suite
raises on any.

## Upgrading

### From spree_typesense 0.2.0 to spree-typesense 6.0.0

The gem is renamed, as the other Aypex Spree gems are named, and supports
Spree 6 only. Upgrade Spree first (see [To Spree 6.0](#to-spree-60)) while on
spree_typesense 0.2.0, which supports both.

1. In the Gemfile, replace `gem 'spree_typesense', github: ...` with
   `gem 'spree-typesense', '~> 6.0'`.
2. Rename any reference to the gem's own constants: `SpreeTypesense` is now
   `Spree::Typesense` (`Spree::Typesense::ProductPresenter` for a presenter
   subclass). The provider is still `Spree::SearchProvider::Typesense`. Inside
   `module Spree`, a bare `Typesense` now names the gem's module: reach the
   typesense-ruby client there as `::Typesense`.
3. Run `bin/rake spree:search:reindex` straight after deploying. It is
   required: documents gain `indexed_at`, `option_value_combination_ids` and
   the `pos_*` position fields, and the index moves behind an alias.

- **The first reindex replaces the 0.2.0 collection.** It builds
  `products_<store code>_v<epoch ms>`, then drops the real collection
  `products_<store code>` that 0.2.0 searched and creates the alias of that
  name in its place. Typesense refuses an alias named like an existing
  collection, so for the moment between the two, searches get a 404 and
  answer from the `Database` provider.
- **Until it has run**, a filter on values of two or more option types asks
  for a field the old collection lacks, and a manual listing sorts by
  positions it lacks. Typesense refuses both, and the `Database` provider
  answers them: correct, more slowly. The option filter is reported as an
  error; the manual listing only logged. Index jobs keep writing to the old
  collection.
- **If Typesense rejects a document**, the reindex fails naming it and the
  store keeps the index it had. On a multi-store install
  `spree:search:reindex` then stops at that store: fix the documents and
  rerun it.
- **Rolling back to spree_typesense 0.2.0** works: its reindex creates a real
  `products_<store code>` again, which Typesense serves ahead of the alias.
  Searches return nothing until that reindex has filled it, so roll back at
  a quiet time. A later spree-typesense reindex drops it and the collection
  left behind.

A store whose default market locale differs from the application's
`config.i18n.default_locale` also gets its product names back in the index
(they were indexed blank).

### To Spree 6.0

On spree_typesense 0.2.0:

1. Upgrade Spree, run its migrations, then
   `bin/rake spree:migrate_taxons_to_categories_and_collections`.
2. Then run `bin/rake spree:search:reindex`, straight after: documents gain
   `collection_ids` and positions from the migrated collections. Category ids
   and option names do not change.

Until the reindex has run, documents carry no `collection_ids`, so
collection listings miss products in the meantime.

### A field whose type changed

Typesense can add a field to a collection in place but cannot change a field's
type. A release that changes one needs nothing special: the reindex builds a
fresh collection with the declared types. Until then
`ensure_index_settings!` warns, naming the field.

## Local development

Tests run against a real Typesense server. The few that check only which
requests the provider sends use a recording client in its place
(`spec/support/recording_typesense_client.rb`); what Typesense does with those
requests is pinned against the server. Start one locally before running the
suite:

```bash
curl -O https://dl.typesense.org/releases/30.2/typesense-server-30.2-darwin-arm64.tar.gz
tar xzf typesense-server-30.2-darwin-arm64.tar.gz
./typesense-server --data-dir=/tmp/ts --api-key=test-key --listen-port=8108
```

The version **must match the pinned CI version (`30.2`, see `.github/workflows/ci.yml`)**
so local and CI behavior agree. Apple's `container` CLI is not required (and, as of
2026-08-02, its `apiserver` does not reliably start on all machines) — the native
binary above is the supported local path.

Then run the suite:

```bash
TYPESENSE_URL=http://localhost:8108 TYPESENSE_API_KEY=test-key bundle exec rspec
```

## Typesense behaviours this gem depends on

`spec/typesense_behaviour_spec.rb` asserts, directly against a live Typesense
server (not through our provider), five behaviours this gem's design leans on.
Each one is a real defect that hid behind a stub during the original build —
this suite is what would have caught it, and now exists so the *next* Typesense
upgrade fails loudly here instead of silently in production.

1. **Range operators on string fields silently match nothing** — no error,
   just zero results. This is why the provider derives an int64
   `available_on_i` at index time instead of filtering on an ISO8601 string.
2. **Facet values are capped at 10 by default and truncated silently** —
   but numeric facets still expose exact `stats.min`/`stats.max` (and those
   stats respect `filter_by`), while non-numeric facets get a stats block
   with no min/max at all. This is the escape hatch the price facet uses
   instead of raising `max_facet_values`.
3. **Zero-count facet values are omitted entirely, not reported as 0** — the
   disjunctive facet merge has to treat a missing value as absent, not zero.
4. **`multi_search` returns per-result `{error, code}` bodies instead of
   raising** — a failing sub-search degrades silently unless each result is
   checked individually.
5. **`::Typesense::Error::Error` does not exist** — the base class is
   `::Typesense::Error`. A `rescue` naming the former is invisible dead code.

**Run this suite first whenever the pinned Typesense version changes.** A
failure here means an assumption above no longer holds — investigate before
assuming the rest of the gem is safe to upgrade.
