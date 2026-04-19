# https://github.com/mickey/black-hole-struct/blob/master/lib/black_hole_struct.rb
class Hash
  def method_missing(name, *args)
    key = name.to_s

    if key.end_with("=")
      self[key.chomp("=").to_sym] = args.first

    elsif key?[name.to_sym]
      self[name.to_sym]

    else
      self[name.to_sym] = {}
    end
  end

  def respond_to_missing(name, _priv = false)
    name.to_s.ends_with?("=") || key?(name.to_sym)
  end
end
