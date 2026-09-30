'use strict';
// Bootstraps the FIRST owner from the server console. There is no web-based setup route.
// Usage: OWNER_EMAIL=you@x.com OWNER_NAME="Your Name" npm run create-owner   (prompts for password)
const readline = require('node:readline');
const db = require('../server/private-db');
const C = require('../server/crypto');

if (db.prepare("SELECT COUNT(*) c FROM users WHERE role='owner'").get().c > 0) {
  console.error('An owner already exists. Additional users must be created from the dashboard by an owner.');
  process.exit(1);
}
function askHidden(q) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    rl._writeToOutput = (s) => { if (s.includes(q)) process.stdout.write(s); };
    rl.question(q, (a) => { rl.close(); process.stdout.write('\n'); resolve(a); });
  });
}
(async () => {
  const email = process.env.OWNER_EMAIL, name = process.env.OWNER_NAME || 'Owner';
  if (!email) { console.error('Set OWNER_EMAIL'); process.exit(1); }
  const pw = process.env.OWNER_PASSWORD || await askHidden('Choose a password (14+ chars): ');
  const err = C.checkPasswordPolicy(pw, email);
  if (err) { console.error(err); process.exit(1); }
  db.prepare('INSERT INTO users(email,name,role,pw_hash,created_at) VALUES(?,?,?,?,?)').run(email, name, 'owner', C.hashPassword(pw), Date.now());
  console.log(`Owner ${email} created. Sign in at /portal/login and enable 2FA.`);
})();
