require_relative 'app_base'
require_relative 'prober'

class App < AppBase

  def initialize(externals)
    # Wire the probe routes onto the injected service locator.
    super(externals)
  end

  get_json(:sha,    Prober)
  get_json(:alive?, Prober)
  get_json(:ready?, Prober)

end
