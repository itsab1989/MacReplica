import Foundation
import SQLite3

/// A Launchpad database with the schema and triggers of macOS 14.8 (read from a real Mac), filled with a
/// default-like arrangement: one page of apps and a folder "Other".
public enum SyntheticLaunchpad {
    static let schema = """
    CREATE TABLE dbinfo (key VARCHAR, value VARCHAR);
    CREATE TABLE items (rowid INTEGER PRIMARY KEY ASC, uuid VARCHAR, flags INTEGER, type INTEGER, parent_id INTEGER NOT NULL, ordering INTEGER);
    CREATE TABLE apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR,category_id INTEGER, moddate REAL, bookmark BLOB);
    CREATE TABLE groups (item_id INTEGER PRIMARY KEY, category_id INTEGER, title VARCHAR);
    CREATE TABLE downloading_apps (item_id INTEGER PRIMARY KEY, title VARCHAR, bundleid VARCHAR, storeid VARCHAR, category_id INTEGER, install_path VARCHAR);
    CREATE TABLE image_cache (item_id INTEGER, size_big INTEGER, size_mini INTEGER, image_data BLOB, image_data_mini BLOB);
    CREATE TRIGGER update_items_order BEFORE UPDATE OF ordering ON items WHEN new.ordering > old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
    BEGIN
        UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        UPDATE items SET ordering = ordering - 1 WHERE parent_id = old.parent_id AND ordering BETWEEN old.ordering and new.ordering;
        UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
    END;
    CREATE TRIGGER update_items_order_backwards BEFORE UPDATE OF ordering ON items WHEN new.ordering < old.ordering AND 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
    BEGIN
        UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        UPDATE items SET ordering = ordering + 1 WHERE parent_id = old.parent_id AND ordering BETWEEN new.ordering and old.ordering;
        UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
    END;
    CREATE TRIGGER update_item_parent AFTER UPDATE OF parent_id ON items WHEN 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
    BEGIN
        UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        UPDATE items SET ordering = (SELECT ifnull(MAX(ordering),0)+1 FROM items WHERE parent_id=new.parent_id AND ROWID!=old.rowid) WHERE ROWID=old.rowid;
        UPDATE items SET ordering = ordering - 1 WHERE parent_id = old.parent_id and ordering > old.ordering;
        UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
    END;
    CREATE TRIGGER insert_item AFTER INSERT on items WHEN 0 == (SELECT value FROM dbinfo WHERE key='ignore_items_update_triggers')
    BEGIN
        UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        UPDATE items SET ordering = (SELECT ifnull(MAX(ordering),0)+1 FROM items WHERE parent_id=new.parent_id) WHERE ROWID=new.rowid;
        UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
    END;
    CREATE TRIGGER app_inserted AFTER INSERT ON items WHEN new.type = 4 OR new.type = 5
    BEGIN
        INSERT INTO image_cache VALUES (new.rowid,0,0,NULL,NULL);
    END;
    CREATE TRIGGER app_deleted AFTER DELETE ON items WHEN old.type = 4 OR old.type = 5
    BEGIN
        DELETE FROM image_cache WHERE item_id=old.rowid;
    END;
    CREATE TRIGGER item_deleted AFTER DELETE ON items
    BEGIN
        DELETE FROM apps WHERE rowid=old.rowid;
        DELETE FROM groups WHERE item_id=old.rowid;
        DELETE FROM downloading_apps WHERE item_id=old.rowid;
        UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';
        UPDATE items SET ordering = ordering - 1 WHERE old.parent_id = parent_id AND ordering > old.ordering;
        UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';
    END;
    INSERT INTO dbinfo VALUES ('ignore_items_update_triggers','0'), ('launchpad_root','1'), ('launchpad_version_root','5');
    INSERT INTO items VALUES (1,'ROOTPAGE',0,1,0,0), (2,'HOLDINGPAGE',0,3,1,0), (5,'ROOTPAGE_VERS',0,1,0,0), (6,'P-VERS',0,3,5,0);
    INSERT INTO groups VALUES (1,NULL,NULL), (2,NULL,NULL), (5,NULL,NULL), (6,NULL,NULL);
    """

    /// Creates the database with `apps` on one page and `folder` apps in a folder named "Other" at the end of it.
    @discardableResult
    public static func create(at url: URL, apps: [String], folder: [String] = []) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        var sql = schema + "UPDATE dbinfo SET value=1 WHERE key='ignore_items_update_triggers';\n"
        var id = 100
        sql += "INSERT INTO items VALUES (10,'PAGE1',0,3,1,1); INSERT INTO groups VALUES (10,NULL,NULL);\n"
        for (index, bundle) in apps.enumerated() {
            id += 1
            sql += "INSERT INTO items VALUES (\(id),'A\(id)',0,4,10,\(index)); INSERT INTO apps VALUES (\(id),'\(bundle)','\(bundle)',NULL,NULL,0,NULL);\n"
        }
        if !folder.isEmpty {
            sql += "INSERT INTO items VALUES (20,'F20',0,2,10,\(apps.count)); INSERT INTO groups VALUES (20,NULL,'Other');\n"
            sql += "INSERT INTO items VALUES (21,'F21',0,3,20,0); INSERT INTO groups VALUES (21,NULL,NULL);\n"
            for (index, bundle) in folder.enumerated() {
                id += 1
                sql += "INSERT INTO items VALUES (\(id),'A\(id)',0,4,21,\(index)); INSERT INTO apps VALUES (\(id),'\(bundle)','\(bundle)',NULL,NULL,0,NULL);\n"
            }
        }
        // The version page holds a second, invisible entry of some apps.
        if let first = apps.first {
            id += 1
            sql += "INSERT INTO items VALUES (\(id),'V\(id)',0,4,6,0); INSERT INTO apps VALUES (\(id),'\(first)','\(first)',NULL,NULL,0,NULL);\n"
        }
        sql += "UPDATE dbinfo SET value=0 WHERE key='ignore_items_update_triggers';"
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Number of rows in `apps` (the Dock's own app entries, which a rebuild must never delete).
    public static func appRows(_ url: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM apps", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : -1
    }
}

extension SyntheticLaunchpad {
    /// Pages and folders that have no row in `groups` (the Dock treats such a page as broken).
    public static func containersWithoutGroupRow(_ url: URL) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items i WHERE i.type IN (2,3) AND NOT EXISTS (SELECT 1 FROM groups g WHERE g.item_id=i.rowid)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : -1
    }
}

extension SyntheticLaunchpad {
    /// What the Dock does when an app is installed: a new entry on the last page.
    public static func addApp(_ bundle: String, to url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let sql = """
        INSERT INTO items (uuid, flags, type, parent_id, ordering)
          VALUES ('\(UUID().uuidString)', 0, 4, (SELECT MAX(rowid) FROM items WHERE type=3 AND parent_id=1), 0);
        INSERT INTO apps VALUES (last_insert_rowid(), '\(bundle)', '\(bundle)', NULL, NULL, 0, NULL);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}
