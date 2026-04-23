# https://github.com/mickey/black-hole-struct/blob/master/lib/black_hole_struct.rb
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

  #def respond_to_missing(name, _priv = false)
  #  name.to_s.end_with?("=") || key?(name.to_sym)
  #end

  # Build a Hash with autovivification via a block DSL.
  #
  #   Hash.vivify {
  #     metadata.name = "web"
  #     spec.replicas = 3
  #     spec.selector.matchLabels.app = "web"
  #   }
  #   # => { metadata: { name: "web" }, spec: { replicas: 3, selector: { matchLabels: { app: "web" } } } }
  #
  def self.vivify(&block)
    new.tap { |h| h.instance_exec(&block) }
  end
end
