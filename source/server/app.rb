require_relative 'app_base'

class App < AppBase

  def initialize(externals)
    # Wire the routing table onto the injected service locator.
    super(externals)
  end

  get_json(:prober, :alive?)
  get_json(:prober, :ready?)
  get_json(:prober, :sha)

  # - - - - - - - - - - - - - - - - -
  # The write-API routes (kata_file_create ... kata_checked_out) are added
  # when the spooler becomes a pass-through proxy in front of saver (ADR B1).

end
