'use strict';
// Usage: npm run backup   -> creates data/backups/<timestamp>/ (see README.txt inside it)
const privateDb = require('../server/private-db');
const publicDb = require('../server/public-db');
const { createBackup } = require('../server/backup');
const r = createBackup(privateDb, publicDb);
console.log(`Backup created: ${r.path}`);
console.log(r.keysIncluded ? 'IMPORTANT: move the KEYS-store-separately folder somewhere safe, apart from the data.' : 'Keys come from your environment variables: back those up yourself.');
