# frozen_string_literal: true

version_file = File.read(File.join(__dir__, 'lib/axhub_sdk/version.rb'))
version = version_file.match(/VERSION = '([^']+)'/)[1]

Gem::Specification.new do |spec|
  spec.name = 'axhub-sdk'
  spec.version = version
  spec.summary = 'AX Hub Ruby SDK'
  spec.description = 'Ruby SDK for AX Hub API route facades, error metadata, and conformance-tested client behavior.'
  spec.authors = ['Jocoding AX Partners']
  spec.email = ['opensource@axhub.ai']
  spec.homepage = 'https://github.com/jocoding-ax-partners/axhub-sdk-ruby'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.1'
  spec.files = Dir['lib/**/*.rb'] + %w[LICENSE README.md axhub-sdk.gemspec]
  spec.require_paths = ['lib']
  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'bug_tracker_uri' => "#{spec.homepage}/issues",
    'rubygems_mfa_required' => 'true'
  }

  spec.add_development_dependency 'minitest', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 13.0'
end
