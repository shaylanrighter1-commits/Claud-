'use strict';
// PRIVATE database. All business content lives in `records`/`documents` as AES-256-GCM blobs:
// a stolen database file (or backup) reveals no plan, property, pricing or financing data.
// Integrity rules are enforced by SQLite triggers so they hold even if application code is bypassed.
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const config = require('./config');

const db = new DatabaseSync(path.join(config.dataDir, 'private.db'));
db.exec(`
PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;

CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY, email TEXT UNIQUE NOT NULL COLLATE NOCASE, name TEXT NOT NULL,
  role TEXT NOT NULL CHECK(role IN ('owner','analyst','viewer')),
  pw_hash TEXT NOT NULL, totp_secret BLOB, totp_enabled INTEGER NOT NULL DEFAULT 0,
  active INTEGER NOT NULL DEFAULT 1, must_change_pw INTEGER NOT NULL DEFAULT 0,
  created_by INTEGER REFERENCES users(id), created_at INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS sessions(
  id_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), csrf TEXT NOT NULL,
  created_at INTEGER NOT NULL, last_seen INTEGER NOT NULL, ip TEXT, ua TEXT, twofa_ok INTEGER NOT NULL DEFAULT 0);

CREATE TABLE IF NOT EXISTS login_attempts(key TEXT NOT NULL, ts INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS la_key ON login_attempts(key, ts);

CREATE TABLE IF NOT EXISTS records(
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('plan','property','financing','assumption','report')),
  data BLOB NOT NULL, version INTEGER NOT NULL DEFAULT 1,
  created_by INTEGER NOT NULL REFERENCES users(id), updated_by INTEGER NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS documents(
  id INTEGER PRIMARY KEY, meta BLOB NOT NULL, vault_name TEXT UNIQUE NOT NULL, size INTEGER NOT NULL,
  uploaded_by INTEGER NOT NULL REFERENCES users(id), created_at INTEGER NOT NULL);

CREATE TABLE IF NOT EXISTS audit_log(
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, user_id INTEGER, action TEXT NOT NULL,
  target TEXT, ip TEXT, detail TEXT, prev_hash TEXT NOT NULL, hash TEXT NOT NULL);

-- Audit log is append-only.
CREATE TRIGGER IF NOT EXISTS audit_no_update BEFORE UPDATE ON audit_log BEGIN SELECT RAISE(ABORT,'audit_log is append-only'); END;
CREATE TRIGGER IF NOT EXISTS audit_no_delete BEFORE DELETE ON audit_log BEGIN SELECT RAISE(ABORT,'audit_log is append-only'); END;
-- Accounts are deactivated, never deleted; the last active owner can never be removed or demoted.
CREATE TRIGGER IF NOT EXISTS users_no_delete BEFORE DELETE ON users BEGIN SELECT RAISE(ABORT,'deactivate users instead of deleting'); END;
CREATE TRIGGER IF NOT EXISTS users_keep_owner BEFORE UPDATE OF role, active ON users
  WHEN OLD.role='owner' AND OLD.active=1 AND (NEW.role<>'owner' OR NEW.active=0)
   AND (SELECT COUNT(*) FROM users WHERE role='owner' AND active=1 AND id<>OLD.id)=0
  BEGIN SELECT RAISE(ABORT,'cannot remove the last active owner'); END;
-- Only one owner-role account may be created by anyone but an existing owner.
CREATE TRIGGER IF NOT EXISTS users_owner_insert BEFORE INSERT ON users
  WHEN NEW.role='owner' AND (SELECT COUNT(*) FROM users WHERE role='owner')>0
   AND (NEW.created_by IS NULL OR (SELECT role FROM users WHERE id=NEW.created_by)<>'owner')
  BEGIN SELECT RAISE(ABORT,'only an owner can create owners'); END;
`);
module.exports = db;
