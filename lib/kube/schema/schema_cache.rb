# frozen_string_literal: true

require 'fileutils'
require 'net/http'
require 'uri'

module Kube
  module Schema
    # Lazily downloads individual schema JSON files from the schemas branch
    # on GitHub and caches them locally under Gem.cache_home (XDG_CACHE_HOME).
    #
    # Usage:
    #   Kube::Schema::SchemaCache.fetch("cert-manager.io/certificate_v1")
    #   # => "/home/user/.cache/kube_schema/schemas/cert-manager.io/certificate_v1.json"
    #
    #   Kube::Schema::SchemaCache.read("v1.33.6/deployment")
    #   # => "{...json contents...}"
    #
    module SchemaCache
      BASE_URL = 'https://raw.githubusercontent.com/general-intelligence-systems/kube_schema/refs/heads/schemas'

      class DownloadError < StandardError; end

      class << self
        # Root directory for cached schemas.
        # Defaults to ~/.cache/kube_schema/schemas (or $XDG_CACHE_HOME/kube_schema/schemas).
        def cache_dir
          @cache_dir ||= File.join(Gem.cache_home, 'kube_schema', 'schemas')
        end

        # Override the cache directory (useful for testing).
        attr_writer :cache_dir

        # Returns the local file path for a schema, downloading it if not cached.
        # The file_path should NOT include the .json extension.
        #
        #   SchemaCache.fetch("cert-manager.io/certificate_v1")
        #   # => "/home/user/.cache/kube_schema/schemas/cert-manager.io/certificate_v1.json"
        #
        def fetch(file_path)
          local = local_path(file_path)

          if File.exist?(local)
            local
          else
            download!(file_path, local)
          end
        end

        # Returns the JSON content as a String, downloading if necessary.
        def read(file_path)
          File.read(fetch(file_path))
        end

        # Returns the local path where a schema would be cached (without downloading).
        def local_path(file_path)
          if file_path.end_with?(".json")
            raise "What are you doing???? don't put .json on the end...."
          else
            File.join(cache_dir, "#{file_path}.json")
          end
        end

        # Returns true if the schema is already cached locally.
        def cached?(file_path)
          File.exist?(local_path(file_path))
        end

        # Removes a single cached schema file.
        def evict(file_path)
          path = local_path(file_path)

          if File.exist?(path)
            File.delete(path)
          end
        end

        # Removes the entire cache directory.
        def clear!
          FileUtils.rm_rf(cache_dir)
        end

        private

          def download!(file_path, local)
            url = "#{BASE_URL}/#{file_path}.json"
            uri = URI.parse(url)

            Net::HTTP.get_response(uri).then do |response|
              unless response.is_a?(Net::HTTPSuccess)
                raise DownloadError, "Failed to download schema: #{url} (HTTP #{response.code})"
              end

              FileUtils.mkdir_p(File.dirname(local))
              File.write(local, response.body)
              local
            end
          end
      end
    end
  end
end
