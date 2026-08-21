import GRDB

enum Migrations {
  static func makeMigrator() -> DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("001_accepted_text_and_fts") { database in
      try database.execute(
        sql: """
          CREATE TABLE clips (
              id INTEGER PRIMARY KEY,
              uuid TEXT NOT NULL UNIQUE,
              kind INTEGER NOT NULL,
              hash_version INTEGER NOT NULL,
              dedupe_hash BLOB NOT NULL,
              representation_set_hash BLOB NOT NULL,
              byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
              created_at INTEGER NOT NULL,
              last_seen_at INTEGER NOT NULL,
              copy_count INTEGER NOT NULL DEFAULT 1 CHECK (copy_count >= 1),
              is_pinned INTEGER NOT NULL DEFAULT 0 CHECK (is_pinned IN (0, 1)),
              is_favorite INTEGER NOT NULL DEFAULT 0 CHECK (is_favorite IN (0, 1)),
              deleted_at INTEGER
          );

          CREATE UNIQUE INDEX clips_live_dedupe_hash
              ON clips(hash_version, dedupe_hash)
              WHERE deleted_at IS NULL;

          CREATE INDEX clips_timeline
              ON clips(is_pinned DESC, last_seen_at DESC, id DESC)
              WHERE deleted_at IS NULL;

          CREATE TABLE clip_representations (
              id INTEGER PRIMARY KEY,
              clip_id INTEGER NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
              item_index INTEGER NOT NULL DEFAULT 0 CHECK (item_index >= 0),
              uti TEXT NOT NULL,
              inline_text TEXT NOT NULL,
              byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
              sha256 BLOB NOT NULL,
              created_at INTEGER NOT NULL,
              UNIQUE (clip_id, item_index, uti)
          );

          CREATE TABLE search_documents (
              clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
              body TEXT NOT NULL DEFAULT '',
              updated_at INTEGER NOT NULL
          );

          CREATE VIRTUAL TABLE clip_fts USING fts5(
              body,
              content='search_documents',
              content_rowid='clip_id',
              tokenize='unicode61 remove_diacritics 2',
              prefix='2 3 4'
          );

          CREATE TRIGGER search_documents_ai AFTER INSERT ON search_documents BEGIN
              INSERT INTO clip_fts(rowid, body)
              VALUES (new.clip_id, new.body);
          END;

          CREATE TRIGGER search_documents_ad AFTER DELETE ON search_documents BEGIN
              INSERT INTO clip_fts(clip_fts, rowid, body)
              VALUES ('delete', old.clip_id, old.body);
          END;

          CREATE TRIGGER search_documents_au AFTER UPDATE ON search_documents BEGIN
              INSERT INTO clip_fts(clip_fts, rowid, body)
              VALUES ('delete', old.clip_id, old.body);
              INSERT INTO clip_fts(rowid, body)
              VALUES (new.clip_id, new.body);
          END;
          """)
    }
    return migrator
  }
}
