class Prober

  def initialize(externals)
    # Hold the service locator so ready?/sha can reach the spooler over HTTP.
    @externals = externals
  end

  def alive?
    # Liveness of the client process itself; true if it can answer at all.
    true
  end

  def ready?
    # Readiness delegates to the spooler server's own readiness probe.
    spooler.ready?
  end

  def sha
    # The git commit sha the spooler image was built from.
    spooler.sha
  end

  private

  def spooler
    # The spooler service collaborator.
    @externals.spooler
  end

end
