# frozen_string_literal: true

require 'rake/testtask'

# Minitest task for the ergonomic data-layer unit tests.
Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList['test/data_layer_test.rb']
  t.warning = false
end

# The legacy conformance/operations/regression suites are plain Ruby scripts
# (not minitest); run them as a sanity baseline alongside the data tests.
desc 'Run the legacy script test suites'
task :scripts do
  %w[operations_test conformance_test regression_test all_operations_e2e_test].each do |name|
    file = "test/#{name}.rb"
    next unless File.exist?(file)

    sh 'ruby', file
  end
end

task default: :test
