require_relative '../require_source'
require_source 'externals'

module TestHelpersExternals

  def externals
    @externals ||= Externals.new
  end

  def http
    externals.http
  end

  def prober
    externals.prober
  end

  def saver
    externals.saver
  end

end
