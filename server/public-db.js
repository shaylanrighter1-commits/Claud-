'use strict';
// PUBLIC database: contains only visitor inquiries and owner-approved published content.
// The public-facing code path imports ONLY this module — never private-db.js.
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');
const config = require('./config');

const db = new DatabaseSync(path.join(config.dataDir, 'public.db'));
db.exec(`
PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;
CREATE TABLE IF NOT EXISTS inquiries(
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL,
  phone TEXT, interest TEXT NOT NULL, message TEXT NOT NULL, ip_hash TEXT NOT NULL, handled INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS published_content(
  id INTEGER PRIMARY KEY, slug TEXT UNIQUE NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
  published_at INTEGER NOT NULL, approved_by TEXT NOT NULL, signature TEXT NOT NULL);
`);
module.exports = db;
