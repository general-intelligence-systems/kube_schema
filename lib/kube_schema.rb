# frozen_string_literal: true

# The entry point named after the gem. The library itself lives under
# `Kube::Schema` in lib/kube/schema.rb -- this file exists so that
# `require "kube_schema"` works, which is what anyone who installed a gem
# called kube_schema will try first, and what `gem kit` requires to find the
# deprecation declarations registered by loading the library.
require_relative "kube/schema"
