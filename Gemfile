source 'https://rubygems.org'

gemspec

# No Gemfile.lock is committed — this is a library, not an application — and no
# version is pinned here. The gemspec's `spree_core ~> 6.0` range IS the
# compatibility claim, so CI resolves it fresh and exercises its ends.
#
# CI sets SPREE_CORE_VERSION per matrix leg: 6.0.0, the oldest supported
# release, and the latest 6.0.x (6.0.5 added
# `Spree::Current.with_content_locale`, which 6.0.0 lacks).
if (spree_core_version = ENV['SPREE_CORE_VERSION'])
  gem 'spree_core', spree_core_version
end
