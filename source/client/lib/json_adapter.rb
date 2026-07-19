require 'json'

module JsonAdapter

  def json_pretty(obj)
    # Serialize obj to an indented, human-readable JSON string.
    JSON.pretty_generate(obj)
  end

  def json_parse(s)
    # Parse a JSON string into Ruby objects.
    JSON.parse!(s)
  end

end
