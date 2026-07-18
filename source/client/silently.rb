require 'stringio'

def silently
  # Run the block with $stderr suppressed (used to hush noisy requires).
  old_stderr = $stderr
  $stderr = StringIO.new
  yield
ensure
  $stderr = old_stderr
end
