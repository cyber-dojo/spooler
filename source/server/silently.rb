def silently
  # Run the block with $stderr suppressed, restoring it afterwards.
  old_stderr = $stderr
  $stderr = StringIO.new
  yield
ensure
  $stderr = old_stderr
end
