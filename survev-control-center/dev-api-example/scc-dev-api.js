// scc-dev-api.js — page-side half of the Control Center developer API (protocol "scc-dev" v1).
//
// Copy this file into YOUR OWN game's development / private-test build. It is self-contained (no imports).
// It lets the Control Center extension read snapshots of your game state for visualization and diagnostics.
//
//   const api = new SccDevApi({
//     token: 'the-same-token-you-typed-in-Settings → Developer authorization',
//     env: 'development',                     // 'development' | 'private-test'  (anything else is rejected)
//     sessionId: 'dev-session-1',
//     getMap:      () => ({ world:{w,h}, meta:{unitsPerMeter}, obstacles:[...] }),   // static geometry, sent once
//     getSnapshot: () => ({ camera, self, players, loot, bullets, events, ... }),     // called once per tick()
//   });
//   api.start();
//   // inside your render loop:
//   api.tick();
//
// SECURITY: only enable this in builds served from localhost / a private network, and only with a
// server-issued token. The extension refuses public hosts regardless of what the page sends.

export class SccDevApi {
  constructor({ token, env = 'development', sessionId = 'dev', appName = 'my-game-dev', getMap, getSnapshot }) {
    if (!token) throw new Error('SccDevApi: token is required');
    this.cfg = { token, env, sessionId, appName, getMap, getSnapshot };
    this.authorized = false;
    this._onMsg = this._onMsg.bind(this);
  }

  start() {
    window.addEventListener('message', this._onMsg);
  }

  stop() {
    window.removeEventListener('message', this._onMsg);
    if (this.authorized) this._post({ type: 'bye' });
    this.authorized = false;
  }

  _post(msg) {
    window.postMessage({ source: 'scc-dev-api', v: 1, ...msg }, location.origin);
  }

  _onMsg(e) {
    if (e.source !== window || e.origin !== location.origin) return;
    const d = e.data;
    if (!d || d.source !== 'scc-extension' || d.v !== 1) return;
    if (d.type === 'hello') {
      this._post({
        type: 'authorize',
        nonce: d.nonce,
        env: this.cfg.env,
        token: this.cfg.token,
        sessionId: this.cfg.sessionId,
        app: this.cfg.appName,
      });
    } else if (d.type === 'ack') {
      this.authorized = true;
      if (this.cfg.getMap) this._post({ type: 'map', map: this.cfg.getMap() });
    } else if (d.type === 'revoke') {
      this.authorized = false;
    }
  }

  /** Call once per rendered frame (or at least ~30 Hz). Cheap no-op until the extension is authorized. */
  tick() {
    if (!this.authorized) return;
    this._post({ type: 'snapshot', frame: this.cfg.getSnapshot() });
  }
}
