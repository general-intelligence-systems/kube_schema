# frozen_string_literal: true

require_relative "lib/kube_schema/version"

Gem::Specification.new do |spec|
  spec.name = "kube_schema"
  spec.version = KubeSchema::VERSION
  spec.authors = ["Nathan K"]
  spec.email = ["nathankidd@hey.com"]

  spec.summary = "Objects that represent Kubernetes Schemas."

  spec.description = <<~DESC
    Abstractions are God. Let's give praise and build on the shoulders of giants by using objects to represent schemas. It was written and to it became.
  DESC

  spec.homepage = "https://github.com/n-at-han-k/kube_schema"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features|data)/}) }
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rubocop", "~> 1.21"
end
