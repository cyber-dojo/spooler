require_relative 'prober'

class Externals

  def prober
    # The liveness/readiness/sha probe collaborator.
    @prober ||= Prober.new
  end

end
