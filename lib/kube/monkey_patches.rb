class Hash
  def method_missing(name, *args)
    key = name.to_s

    if key.end_with?("=")
      self[key.chomp("=").to_sym] = args.first

    elsif key?(name.to_sym)
      self[name.to_sym]

    elsif key.start_with?("to_")
      super

    else
      self[name.to_sym] = {}
    end
  end

  # Build a Hash with autovivification via a block DSL.
  # @yields {} a block evaluated against the new Hash.
  # @returns [Hash] the Hash built by the block.
  #
  # @example
  #   Hash.vivify {
  #     metadata.name = "web"
  #     spec.replicas = 3
  #     spec.selector.matchLabels.app = "web"
  #   }
  #   # => { metadata: { name: "web" }, spec: { replicas: 3, selector: { matchLabels: { app: "web" } } } }
  def self.vivify(&block)
    new.tap { |h| h.instance_exec(&block) }
  end

  # Stringify keys so symbols don't leak into YAML as `:key:`.
  # @returns [String] the Hash dumped as YAML.
  def to_yaml(*)
    Hash._deep_stringify_keys(self).then { |h| Psych.dump(h) }
  end

  def self._deep_stringify_keys(obj)
    case obj
    when Hash
      obj.each_with_object({}) do |(k, v), result|
        result[k.to_s] = _deep_stringify_keys(v)
      end
    when Array
      obj.map { |v| _deep_stringify_keys(v) }
    else
      obj
    end
  end
end
