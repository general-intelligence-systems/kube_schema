# frozen_string_literal: true

module Kube
  # Base error for all Kube gems. Catch this to handle any Kube error.
  class Error < StandardError; end

  # Raised when a schema version is unknown.
  class UnknownVersionError < Error; end

  # Raised when a version string is formatted incorrectly (e.g. "v1.33.6").
  class IncorrectVersionFormat < Error; end

  # Raised when a schema download fails.
  class DownloadError < Error
    attr_reader :url, :status_code

    def initialize(message = nil, url: nil, status_code: nil)
      @url         = url
      @status_code = status_code
      super(message || "Failed to download schema: #{@url} (HTTP #{@status_code})")
    end
  end
end
