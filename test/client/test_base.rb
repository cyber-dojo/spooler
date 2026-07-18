require_relative 'id58_test_base'
require_source 'externals'

class TestBase < Id58TestBase

  def externals
    # A fresh service locator wired to the real spooler server over HTTP.
    @externals ||= Externals.new
  end

end
