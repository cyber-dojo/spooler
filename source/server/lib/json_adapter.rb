require 'json'

module JsonAdapter

  def json_plain(obj)
    # Serialize obj to a compact single-line JSON string.
    JSON.generate(obj)
  end

  def json_pretty(obj)
    # Serialize obj to an indented, human-readable JSON string.
    JSON.pretty_generate(obj)
  end

  def json_parse(s)
    # Parse a JSON string into ruby objects, raising on malformed input.
    JSON.parse!(s)
  end

end
