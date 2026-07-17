module Utf8

  def self.clean(s)
    # Strip invalid byte sequences from s, returning valid UTF-8.
    # Round-tripping through UTF-16 forces detection: encoding an
    # already-UTF-8 string to UTF-8 is a no-op that skips validation.
    s = s.encode('UTF-16', 'UTF-8', :invalid => :replace, :replace => '')
    s = s.encode('UTF-8', 'UTF-16')
  end

end

# http://robots.thoughtbot.com/fight-back-utf-8-invalid-byte-sequences
