'use strict';
const express = require('express');
const path = require('node:path');
const config = require('./config');
const S = require('./security');

const app = express();
app.disable('x-powered-by');
if (config.trustProxy) app.set('trust proxy', 1);

app.use(S.forceHttps, S.hostGuard);

if (config.mode !== 'portal') {
  // PUBLIC site. In SERVE_MODE=public the private DB, data key and portal code are never loaded.
  const { router } = require('./routes/public');
  app.use('/portal', (req, res, next) => (config.mode === 'public' ? res.status(404).end() : next()));
  app.use((req, res, next) => (req.path.startsWith('/portal') ? next() : S.headers(false)(req, res, next)));
  app.use(router);
  app.use(express.static(path.join(__dirname, '..', 'public'), { dotfiles: 'ignore', index: 'index.html', extensions: ['html'], maxAge: '1h' }));
}
if (config.mode !== 'public') {
  app.use('/portal', S.headers(true), require('./routes/portal'));
  if (config.mode === 'portal') app.get('/', (req, res) => res.redirect('/portal/'));
}
app.use((req, res) => res.status(404).set('X-Robots-Tag', 'noindex').type('text/plain').send('Not found'));
// Generic error handler: never leak stack traces or internals.
app.use((err, req, res, next) => { // eslint-disable-line no-unused-vars
  if (err.type === 'entity.too.large') return res.status(413).json({ error: 'Payload too large' });
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid JSON' });
  console.error('[error]', req.method, req.path, err.message);
  res.status(500).json({ error: 'Internal error' });
});

if (require.main === module) app.listen(config.port, () => console.log(`[${config.mode}] listening on :${config.port}`));
module.exports = app;
