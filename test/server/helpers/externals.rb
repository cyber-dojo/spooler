require_relative '../require_source'
require_source 'externals'
require_source 'model'

module TestHelpersExternals

  def externals
    @externals ||= Externals.new
  end

  def model
    # The domain model under test, built from the same externals the injection
    # helpers (in_memory_db, saver_returns, time_is) mutate, so a stub swapped
    # into externals is seen by the model's spool and drainer.
    @model ||= Model.new(externals)
  end

  def prober
    model.prober
  end

end
