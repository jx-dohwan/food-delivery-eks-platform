import { randomUUID } from 'node:crypto';
export class SessionUnitStore {
  rows = new Map<string, { sid: string; refresh_hash: string }>();
  current(id: string) { return Promise.resolve(this.rows.get(id) ?? null); }
  put(id: string, sid: string, hash: string, _ttl: number) { this.rows.set(id, { sid, refresh_hash: hash }); return Promise.resolve(); }
  rotate(id: string, sid: string, old: string, next: string, _ttl: number) {
    const r = this.rows.get(id); if (!r || r.sid !== sid || r.refresh_hash !== old) return Promise.resolve(false);
    this.rows.set(id, { sid, refresh_hash: next }); return Promise.resolve(true);
  }
  revoke(id: string, sid: string) { const r = this.rows.get(id); return Promise.resolve(r?.sid === sid && this.rows.delete(id)); }
  claims(id: string) { const sid = randomUUID(); this.rows.set(id, { sid, refresh_hash: '0'.repeat(64) }); return { sub: id, sid, jti: randomUUID(), type: 'access' }; }
}
