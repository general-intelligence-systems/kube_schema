module KubeSchema
  class SchemaIndex
    def initialize(version)
      @version = version
    end

    def find(query)
      all_paths.select { _1.include?(query.downcase) }.first
    end

    def all_paths
      kubernetes_paths + custom_resource_paths
    end

    def custom_resource_paths
      File.read(SCHEMA_INDEX + "/crds.txt").lines.map do |line|
        line.chomp.gsub(".json", "")
      end
    end

    def kubernetes_paths
      File.read(SCHEMA_INDEX + "/v#{@version}.txt").lines.map do |line|
        line.chomp.gsub(".json", "")
      end
    end
  end
end
