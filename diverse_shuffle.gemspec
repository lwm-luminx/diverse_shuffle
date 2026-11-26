# frozen_string_literal: true

require_relative 'lib/diverse_shuffle/version'

Gem::Specification.new do |spec|
  spec.name = 'diverse_shuffle'
  spec.version = DiverseShuffle::Engine::VERSION
  spec.authors = ['Love Wins Media, Inc.']
  spec.summary = 'A seeded shuffle where neighbouring songs are not too alike, in Rust with a pure-Ruby fallback.'
  spec.description = <<~TEXT
    Places songs in a random order under hard rules (how far apart neighbouring songs must be, by measured distance
    or by shared attributes) with a soft score for how spread out the order is: greedy, MMR or DPP. The same seed
    gives the same order from the Rust engine or the Ruby one.
  TEXT
  spec.homepage = 'https://github.com/lwm-luminx/diverse_shuffle'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.4'
  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*.rb', 'ext/**/*.{rs,rb,toml}', 'Cargo.toml', 'Cargo.lock', 'README.md', 'CHANGELOG.md',
                   'LICENSE']
  spec.require_paths = ['lib']
  spec.extensions = ['ext/diverse_shuffle/extconf.rb']

  spec.add_dependency 'rb_sys', '~> 0.9'
end
