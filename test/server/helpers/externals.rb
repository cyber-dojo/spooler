require_relative '../require_source'
require_source 'externals'

module TestHelpersExternals

  def externals
    @externals ||= Externals.new
  end

  def prober
    externals.prober
  end

end
