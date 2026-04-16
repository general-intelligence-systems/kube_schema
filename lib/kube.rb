# frozen_string_literal: true

require_relative "kube/schema"

module Kube
  def self.schema
    Schema
  end
end
