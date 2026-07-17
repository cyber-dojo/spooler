require_relative 'id58_test_base'
require_relative 'capture_stdout_stderr'
require_relative 'helpers/externals'
require_relative 'helpers/rack'
require_relative 'require_source'
require 'json'

class TestBase < Id58TestBase

  include CaptureStdoutStderr
  include TestHelpersExternals
  include TestHelpersRack

  # An arbitrary well-formed laptop_id (SecureRandom.hex(32) format), used to
  # make event bodies in tests look like a real client's. Its value is not
  # significant.
  def laptop_id
    '9b1c7f0e4a2d6538c1e0fb94a7d213e6f5028b4c9de71a36085fc2b7d419e0a2'
  end

end
