class Prober

  def alive?
    # Liveness probe: the process is up and serving HTTP.
    true
  end

  def ready?
    # Readiness probe: the service is ready to accept requests.
    true
  end

  def sha
    # The git commit sha this image was built from.
    ENV['COMMIT_SHA']
  end

end
