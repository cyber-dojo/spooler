require_relative 'test_base'

class ExternalsTest < TestBase

  test 'Ex0001', %w(
  | db is the durable buffer in the file at the db_path the externals were
  | given: a write appended through it is read back by a second connection
  | to the same file
  ) do
    db_path = "/tmp/#{id58}.db"
    Externals.new(db_path: db_path).db.append(
      path: 'kata_ran_tests', body: ran_tests_body,
      kata_id: id58, laptop_id: laptop_id, tab_seq: 4, enqueued_at: 1000
    )
    kata_ids = External::Db.new(db_path).buffered_events.map { |event| event['kata_id'] }
    assert_equal [id58], kata_ids
  end

end
