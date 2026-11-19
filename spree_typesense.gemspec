require_relative 'lib/spree_typesense/version'

Gem::Specification.new do |s|
  s.name        = 'spree_typesense'
  s.version     = SpreeTypesense::VERSION
  s.summary     = 'Typesense search provider for Spree'
  s.description = 'A Typesense search provider for Spree Commerce 5.5 to 6.0: search, filters, facets and ' \
                  'sorting through Spree::SearchProvider::Base, with a fallback to the Database provider.'
  s.authors     = ['Aypex']
  s.homepage    = 'https://github.com/aypex-io/spree_typesense'
  s.license     = 'MIT'
  s.files       = Dir['lib/**/*', 'app/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md']
  s.required_ruby_version = '>= 3.3'

  s.metadata = {
    'source_code_uri' => s.homepage,
    'bug_tracker_uri' => "#{s.homepage}/issues",
    'changelog_uri' => "#{s.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  s.add_dependency 'spree_core', '>= 5.5', '< 6.1'
  s.add_dependency 'typesense', '~> 5.0'

  s.add_development_dependency 'rake', '~> 13.0'
  s.add_development_dependency 'rspec', '~> 3.13'
end
