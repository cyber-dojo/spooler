require_relative 'app_base'

class App < AppBase

  def initialize(model)
    # Wire the routing table onto the injected domain model.
    super(model)
  end

  get_json(:prober, :alive?)
  get_json(:prober, :ready?)
  get_json(:prober, :sha)

  # - - - - - - - - - - - - - - - - -
  # Write API: each POST durably appends the write to the spool and acks 200; the
  # drainer forwards to saver asynchronously. Reads stay direct web->saver, so
  # only writes appear here (kata_file_create ... kata_checked_out).

  post_write(:kata_file_create)
  post_write(:kata_file_delete)
  post_write(:kata_file_rename)
  post_write(:kata_file_edit)

  post_write(:kata_ran_tests)
  post_write(:kata_predicted_right)
  post_write(:kata_predicted_wrong)
  post_write(:kata_reverted)
  post_write(:kata_checked_out)

end
