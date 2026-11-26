# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rb_sys/extensiontask'
require 'rspec/core/rake_task'

GEMSPEC = Gem::Specification.load('diverse_shuffle.gemspec')

RbSys::ExtensionTask.new('diverse_shuffle', GEMSPEC) do |ext|
  ext.lib_dir = 'lib/diverse_shuffle'
end

RSpec::Core::RakeTask.new(:spec)

task default: %i[compile spec]
