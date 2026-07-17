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
  # Pass-through write API (ADR B1): each POST is relayed to saver verbatim,
  # including a 500. Reads stay direct web->saver, so only writes appear here.
  # The range is saver's per-kata event writes (kata_file_create ... kata_checked_out).

  post_pass_through(:kata_file_create)
  post_pass_through(:kata_file_delete)
  post_pass_through(:kata_file_rename)
  post_pass_through(:kata_file_edit)

  post_pass_through(:kata_ran_tests)
  post_pass_through(:kata_predicted_right)
  post_pass_through(:kata_predicted_wrong)
  post_pass_through(:kata_reverted)
  post_pass_through(:kata_checked_out)

end
