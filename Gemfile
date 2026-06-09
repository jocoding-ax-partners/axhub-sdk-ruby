# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# minitest ships with Ruby, but pinning it here makes `bundle install` /
# `bundle exec rake test` reproducible across Ruby versions.
group :development, :test do
  gem 'minitest', '~> 5.0'
  gem 'rake', '~> 13.0'
end
