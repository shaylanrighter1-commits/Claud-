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
    if (!process.stdin.isTTY) { // piped input (CI): read a line without echo concerns
      const rl = readline.createInterface({ input: process.stdin });
      rl.question('', (a) => { rl.close(); resolve(a); });
      return;
    }
    process.stdout.write(q);
    let pw = '';
    readline.emitKeypressEvents(process.stdin);
    process.stdin.setRawMode(true); process.stdin.resume();
    const onKey = (str, key) => {
      if (key.name === 'return' || key.name === 'enter') {
        process.stdin.setRawMode(false); process.stdin.pause(); process.stdin.off('keypress', onKey);
        process.stdout.write('\n'); resolve(pw);
      } else if (key.ctrl && key.name === 'c') process.exit(130);
      else if (key.name === 'backspace') pw = pw.slice(0, -1);
      else if (str) pw += str;
    };
    process.stdin.on('keypress', onKey);
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
