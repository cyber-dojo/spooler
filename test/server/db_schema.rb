require_relative 'test_base'
require_source 'external/db'

class DbSchemaTest < TestBase

  test 'Db0001', %w(
  | opening a Db on a fresh database creates an empty events table
  ) do
    in_temp_db do |db|
      assert_equal 0, db.event_count(kata_id: 'AbCd3E')
    end
  end

  test 'Db0002', %w(
  | the database is opened in WAL journal mode
  ) do
    in_temp_db do |db|
      assert_equal 'wal', db.journal_mode
    end
  end

  test 'Db0003', %w(
  | a busy writer waits up to busy_timeout ms rather than erroring immediately
  ) do
    in_temp_db do |db|
      assert_equal 5000, db.busy_timeout
    end
  end

  test 'Db0004', %w(
  | appended writes are read back and counted per kata, oldest first, with
  | each kata isolated from the others
  ) do
    in_temp_db do |db|
      db.append(path: 'kata_file_edit', body: '{"id":"AbCd3E"}',
                kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1)
      db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
                kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 2)
      db.append(path: 'kata_file_edit', body: '{"id":"Xy9k2P"}',
                kata_id: 'Xy9k2P', laptop_id: laptop_id, tab_seq: 1)
      assert_equal 2, db.event_count(kata_id: 'AbCd3E')
      assert_equal 1, db.event_count(kata_id: 'Xy9k2P')
      rows = db.events_for(kata_id: 'AbCd3E')
      assert_equal %w(kata_file_edit kata_ran_tests), rows.map { |row| row['path'] }
    end
  end

  test 'Db0005', %w(
  | an appended write stays in the buffer until it is deleted by the id that
  | append returned (delete-on-ack: presence in the buffer means undrained)
  ) do
    in_temp_db do |db|
      id = db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
                     kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 1)
      assert_equal 1, db.buffered_events.size
      db.delete(id)
      assert_equal 0, db.buffered_events.size
    end
  end

  test 'Db0006', %w(
  | re-appending a write with the same (kata_id, laptop_id, tab_seq) is deduped
  | to a single buffered row, and append returns that original row's id (not the
  | most-recently-inserted row's) so the right row is drained
  ) do
    in_temp_db do |db|
      first = db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
                        kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 7)
      db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
                kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 8)
      redelivered = db.append(path: 'kata_ran_tests', body: '{"id":"AbCd3E"}',
                              kata_id: 'AbCd3E', laptop_id: laptop_id, tab_seq: 7)
      assert_equal first, redelivered
      assert_equal 2, db.buffered_events.size
    end
  end

  private

  def in_temp_db
    # Open an External::Db on a throwaway file (WAL needs a real file, not
    # :memory:), yield it, then close and delete the file and its WAL sidecars.
    path = "/tmp/spooler_#{id58}.db"
    db = External::Db.new(path)
    begin
      yield db
    ensure
      db.close
      ['', '-wal', '-shm'].each { |suffix| File.delete(path + suffix) rescue nil }
    end
  end

end
