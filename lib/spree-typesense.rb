# Bundler auto-requires a gem by its *name*, so `gem 'spree-typesense'` in a host
# Gemfile issues `require 'spree-typesense'`. The gem's real entry point is
# `spree/typesense`, matching the Spree::Typesense namespace, so this shim keeps
# the default `Bundler.require` working without every consumer having to write
# `gem 'spree-typesense', require: 'spree/typesense'`.
require 'spree/typesense'
