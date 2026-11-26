# frozen_string_literal: true

require 'mkmf'

# Without a Rust toolchain the extension isn't built and the Ruby engine places songs instead (same results, slower):
# the install still succeeds. The platform gems are precompiled, so this only matters for the source gem.
if find_executable('cargo')
  require 'rb_sys/mkmf'
  create_rust_makefile('diverse_shuffle/diverse_shuffle')
else
  warn 'diverse_shuffle: no Rust toolchain (cargo) found, so the Rust engine is not built; using the Ruby engine.'
  File.write('Makefile', "all install clean:\n\t@:\n.PHONY: all install clean\n")
end
