'use strict';
// Resets one user's password from the server console. Keeps all data. Clears lockouts and sessions.
// Usage: USER_EMAIL=you@x.com npm run reset-password        (add RESET_2FA=1 if you lost your authenticator)
const readline = require('node:readline');
const db = require('../server/private-db');
const C = require('../server/crypto');

function askHidden(q) {
  return new Promise((resolve) => {
    process.stdout.write(q);
    let pw = '';
    readline.emitKeypressEvents(process.stdin);
    if (process.stdin.isTTY) process.stdin.setRawMode(true);
    process.stdin.resume();
    const onKey = (str, key) => {
      if (key && (key.name === 'return' || key.name === 'enter')) {
        if (process.stdin.isTTY) process.stdin.setRawMode(false);
        process.stdin.pause(); process.stdin.off('keypress', onKey); process.stdout.write('\n'); resolve(pw);
      } else if (key && key.ctrl && key.name === 'c') process.exit(130);
      else if (key && key.name === 'backspace') pw = pw.slice(0, -1);
      else if (str) pw += str;
    };
    process.stdin.on('keypress', onKey);
  });
}
(async () => {
  const email = process.env.USER_EMAIL;
  if (!email) { console.error('Set USER_EMAIL, e.g. USER_EMAIL=you@x.com npm run reset-password'); process.exit(1); }
  const u = db.prepare('SELECT id,email FROM users WHERE email=?').get(email);
  if (!u) { console.error(`No user with email ${email}. Check the spelling.`); process.exit(1); }
  const pw = process.env.NEW_PASSWORD || await askHidden('New password (14+ chars, hidden): ');
  const err = C.checkPasswordPolicy(pw, u.email);
  if (err) { console.error(err); process.exit(1); }
  db.prepare('UPDATE users SET pw_hash=?, must_change_pw=0, active=1 WHERE id=?').run(C.hashPassword(pw), u.id);
  if (process.env.RESET_2FA === '1') db.prepare('UPDATE users SET totp_secret=NULL, totp_enabled=0 WHERE id=?').run(u.id);
  db.prepare('DELETE FROM sessions WHERE user_id=?').run(u.id);
  db.prepare('DELETE FROM login_attempts').run();
  console.log(`Password updated for ${u.email}. You can sign in now.`);
  process.exit(0);
})();
