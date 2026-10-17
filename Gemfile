# frozen_string_literal: true

source "https://rubygems.org"

# The gem's own dependencies are listed here rather than pulled in with
# `gemspec`. A `gemspec` line makes bundler treat kube_schema as a path gem,
# and bundlerEnv then resolves that path to its own store-only Gemfile
# directory: the gemspec's `git ls-files` fails there ("not a git repository")
# and its lib/ lands on the load path next to the working tree's, which
# redefines every constant. Keep this list in sync with kube_schema.gemspec.
gem "json_schemer", "~> 2.5.0"
gem "rubyshell", "~> 1.5.0"

gem "lefthook", "~> 2.1"
gem "rake", "~> 13.0"
gem "scampi", "~> 1.0"

group :maintenance, optional: true do
	gem "utopia-project"
	gem "bake-gem"
	gem "bake-modernize"
	gem "bake-releases"
end
