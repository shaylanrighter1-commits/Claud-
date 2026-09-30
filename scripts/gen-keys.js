'use strict';
const c = require('node:crypto');
console.log('# Paste into your secret manager / .env (never commit)');
console.log('DATA_KEY=' + c.randomBytes(32).toString('base64'));
console.log('PUBLISH_KEY=' + c.randomBytes(32).toString('base64'));
