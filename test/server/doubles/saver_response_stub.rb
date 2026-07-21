# A canned saver response answering the three methods the pass-through relays:
# code (status), content_type, and body. code may be an Integer; the relay
# calls code.to_i.
class SaverResponseStub

  attr_reader :code, :body, :content_type

  def initialize(code:, body:, content_type: 'application/json')
    @code = code
    @body = body
    @content_type = content_type
  end

end
