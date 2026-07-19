require 'sqlite3'

module External

  class Db

    def initialize(path)
      # Open (creating if absent) the SQLite database at path, put it in WAL
      # mode for crash-safe durability with a reader/writer split, and ensure
      # the events buffer table exists.
      @db = SQLite3::Database.new(path)
      @db.execute('PRAGMA journal_mode=WAL;')
      # Multiple puma workers (and, briefly, a blue/green pair) each hold their
      # own connection to this one file. WAL serialises writers; busy_timeout
      # makes a writer that collides wait rather than erroring SQLITE_BUSY.
      @db.execute('PRAGMA busy_timeout=5000;')
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS events (
          id        INTEGER PRIMARY KEY,
          kata_id   TEXT,
          laptop_id TEXT,
          tab_seq   INTEGER,
          path      TEXT NOT NULL,
          body      TEXT NOT NULL,
          UNIQUE(kata_id, laptop_id, tab_seq)
        );
      SQL
    end

    def append(path:, body:, kata_id:, laptop_id:, tab_seq:)
      # Persist one write as a buffered event row and return its row id. kata_id
      # is the kata the write belongs to (each kata is its own ordered log); path
      # is the write method name; body its verbatim request body. A row stays
      # buffered (undrained) until delete drains it.
      #
      # (kata_id, laptop_id, tab_seq) is the idempotency key: a redelivered write
      # still in the buffer is deduped to one row (a no-op UPSERT), and its
      # original id is returned so the caller drains the right row. A write whose
      # key has a nil part (no tab_seq) is not deduped - SQLite treats NULLs as
      # distinct in the UNIQUE constraint - which is correct: it has no key.
      rows = @db.execute(<<~SQL, [path, body, kata_id, laptop_id, tab_seq])
        INSERT INTO events (path, body, kata_id, laptop_id, tab_seq)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(kata_id, laptop_id, tab_seq) DO UPDATE SET path = path
        RETURNING id;
      SQL
      rows[0][0]
    end

    def delete(id)
      # Drain one row: saver has acked its write, so it leaves the buffer
      # (delete-on-ack). Presence in the buffer therefore means undrained.
      @db.execute('DELETE FROM events WHERE id = ?;', [id])
    end

    def buffered_events
      # Every undrained row, oldest first, as string-keyed hashes. Boot replay
      # re-forwards these; each is deleted once saver acks it.
      rows = @db.execute('SELECT id, kata_id, path, body FROM events ORDER BY id;')
      rows.map do |id, kata_id, path, body|
        { 'id' => id, 'kata_id' => kata_id, 'path' => path, 'body' => body }
      end
    end

    def events_for(kata_id:)
      # One kata's buffered event rows, oldest first, as string-keyed hashes.
      rows = @db.execute(
        'SELECT id, kata_id, path, body FROM events WHERE kata_id = ? ORDER BY id;',
        [kata_id]
      )
      rows.map do |id, kata_id, path, body|
        { 'id' => id, 'kata_id' => kata_id, 'path' => path, 'body' => body }
      end
    end

    def event_count(kata_id:)
      # The number of buffered event rows for one kata.
      @db.get_first_value('SELECT COUNT(*) FROM events WHERE kata_id = ?;', [kata_id])
    end

    def journal_mode
      # The database journal mode (expected to be 'wal').
      @db.get_first_value('PRAGMA journal_mode;')
    end

    def busy_timeout
      # The lock-wait timeout in ms a colliding writer blocks for.
      @db.get_first_value('PRAGMA busy_timeout;')
    end

    def close
      # Close the underlying database handle.
      @db.close
    end

  end

end
