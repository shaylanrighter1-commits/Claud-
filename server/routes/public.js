'use strict';
// PUBLIC surface. Imports only the public database. No route here can reach private data.
const express = require('express');
const db = require('../public-db');
const config = require('../config');
const C = require('../crypto');
const { rateLimit, ipHash } = require('../security');

const router = express.Router();
const str = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const INTERESTS = ['Investing with us', 'Selling a property', 'Partnering / lending', 'Careers', 'General question'];

router.post('/api/public/inquiries', rateLimit('inq', 5, 60 * 60 * 1000), express.json({ limit: '10kb' }), (req, res) => {
  const b = req.body || {};
  if (b.website) return res.json({ ok: true });                        // honeypot: silently drop bots
  const name = str(b.name, 100), email = str(b.email, 200), phone = str(b.phone, 40), message = str(b.message, 4000);
  const interest = INTERESTS.includes(b.interest) ? b.interest : 'General question';
  if (!name || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || message.length < 10) return res.status(400).json({ error: 'Please complete name, a valid email, and a message.' });
  db.prepare('INSERT INTO inquiries(ts,name,email,phone,interest,message,ip_hash) VALUES(?,?,?,?,?,?,?)')
    .run(Date.now(), name, email, phone, interest, message, ipHash(req.ip));
  res.json({ ok: true });
});

// Only rows the owner explicitly published AND whose HMAC signature verifies are ever served.
const sig = (r) => C.hmac(config.publishKey, [r.slug, r.title, r.body, r.published_at].join('\u001f'));
router.get('/api/public/content', (req, res) => {
  const rows = db.prepare('SELECT * FROM published_content ORDER BY published_at DESC').all()
    .filter((r) => C.safeEqual(sig(r), r.signature))
    .map(({ slug, title, body, published_at }) => ({ slug, title, body, publishedAt: published_at }));
  res.set('Cache-Control', 'public, max-age=300').json(rows);
});

module.exports = { router, sig };
