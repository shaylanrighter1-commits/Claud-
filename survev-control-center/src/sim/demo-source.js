// Snapshot source backed by the synthetic World (interactive: the app feeds it player input).

import { World } from './world.js';

export class DemoSource {
  constructor(opts) {
    this.kind = 'demo';
    this.interactive = true;
    this.label = 'Demo Arena';
    this.world = new World(opts);
    this.zoom = 1;
    this.cam = { x: this.world.self.x, y: this.world.self.y };
    this.last = null;
  }

  reset(opts) {
    this.world.reset(opts);
    this.cam = { x: this.world.self.x, y: this.world.self.y };
    this.last = null;
  }

  setZoom(z) {
    this.zoom = Math.min(1.8, Math.max(0.5, z));
  }

  peek() {
    return this.last;
  }

  update(dt, input) {
    this.world.advance(dt, input);
    const me = this.world.self;
    const k = 1 - Math.exp(-dt * 10);
    this.cam.x += (me.x - this.cam.x) * k;
    this.cam.y += (me.y - this.cam.y) * k;
    const snap = this.world.snapshot();
    snap.camera = { x: this.cam.x, y: this.cam.y, scale: this.zoom };
    this.last = snap;
    return snap;
  }
}
