// Approved U06 policy. Runtime registration is owned by JwtModule.
import { ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { createHash, randomUUID } from 'node:crypto';
import type Redis from 'ioredis';
import { isUUID } from 'class-validator';
import { writeEvent } from '../logger/safe-event';
import { SessionAuthority } from './session-authority';

export const SESSION_REDIS_OPTIONS = Object.freeze({
  connectTimeout: 1000,
  commandTimeout: 1000,
  maxRetriesPerRequest: 1,
  enableOfflineQueue: false,
  autoResendUnfulfilledCommands: false,
});

// Compare and replace/expire are ONE server-side operation. No raw JWT in Redis.
export const SESSION_ROTATE = `
local raw = redis.call('GET', KEYS[1])
if not raw then return 0 end
local ok, record = pcall(cjson.decode, raw)
if not ok or type(record) ~= 'table' then return 0 end
if record.sid ~= ARGV[1] or record.refresh_hash ~= ARGV[2] then return 0 end
redis.call('SET', KEYS[1], ARGV[3], 'EX', ARGV[4])
return 1
`;
export const SESSION_REVOKE = `
local raw = redis.call('GET', KEYS[1])
if not raw then return 0 end
local ok, record = pcall(cjson.decode, raw)
if not ok or type(record) ~= 'table' or record.sid ~= ARGV[1] then return 0 end
return redis.call('DEL', KEYS[1])
`;

interface SessionRecord { sid: string; refresh_hash: string }
export interface SessionClaims { sub: string; sid: string; jti: string; exp: number; type: 'access' | 'refresh' }
interface SessionOptions { accessSecret: string; refreshSecret: string; accessSeconds: number; refreshSeconds: number }
type Emit = typeof writeEvent;
const digest = (value: string) => createHash('sha256').update(value).digest('hex');

export class SessionStore {
  private failed = false;
  constructor(private readonly redis: Redis, private readonly authority: SessionAuthority, private readonly emit: Emit = writeEvent) {}

  private key(userId: string): string {
    if (!isUUID(userId)) throw new UnauthorizedException('Invalid session');
    return `food-delivery/session/v1/${userId}`;
  }

  private async command<T>(run: () => Promise<T>): Promise<T> {
    try {
      if (this.redis.status !== 'ready') throw new Error('Unavailable');
      const result = await run();
      if (this.failed) this.emit('redis.ready');
      this.failed = false;
      return result;
    } catch {
      if (!this.failed) this.emit('redis.failed', 'ERROR', { error_type: 'ServiceUnavailableException' });
      this.failed = true;
      throw new ServiceUnavailableException('Authentication temporarily unavailable');
    }
  }

  async current(userId: string): Promise<SessionRecord | null> {
    const key = this.key(userId);
    const raw = await this.command(() => this.redis.get(key));
    if (raw === null) return null;
    try {
      const row = JSON.parse(raw);
      if (!(row && typeof row.sid === 'string' && isUUID(row.sid)
        && typeof row.refresh_hash === 'string' && /^[a-f0-9]{64}$/.test(row.refresh_hash))) return null;
      // SQL errors must propagate as 503, not be caught as malformed Redis data.
      return await this.authorizedRecord(userId, row);
    } catch (error) {
      if (error instanceof ServiceUnavailableException) throw error;
      return null;
    }
  }

  private async authorizedRecord(userId: string, row: SessionRecord): Promise<SessionRecord | null> {
    const current = await this.authority.current(userId);
    return current?.sid === row.sid ? row : null;
  }

  async put(userId: string, sid: string, tokenHash: string, ttl: number): Promise<void> {
    const key = this.key(userId);
    await this.authority.put(userId, sid, tokenHash, ttl);
    await this.command(() => this.redis.set(key, JSON.stringify({ sid, refresh_hash: tokenHash }), 'EX', ttl));
  }

  async rotate(userId: string, sid: string, oldHash: string, newHash: string, ttl: number): Promise<boolean> {
    const key = this.key(userId);
    const before = await this.current(userId);
    if (!before || before.sid !== sid || before.refresh_hash !== oldHash) return false;
    if (!await this.authority.rotate(userId, sid, oldHash, newHash, ttl)) return false;
    const result = await this.command(() => this.redis.eval(SESSION_ROTATE, 1, key,
      sid, oldHash, JSON.stringify({ sid, refresh_hash: newHash }), ttl));
    return result === 1;
  }

  async revoke(userId: string, sid: string): Promise<boolean> {
    const key = this.key(userId);
    if (!await this.authority.revoke(userId, sid)) return false;
    await this.command(() => this.redis.eval(SESSION_REVOKE, 1, key, sid));
    return true;
  }
}

export class SessionPolicy {
  constructor(private readonly jwt: JwtService, private readonly store: SessionStore,
    private readonly options: SessionOptions, private readonly emit: Emit = writeEvent) {
    if (!options.accessSecret || !options.refreshSecret || options.accessSecret === options.refreshSecret
      || !Number.isSafeInteger(options.accessSeconds) || options.accessSeconds <= 0
      || !Number.isSafeInteger(options.refreshSeconds) || options.refreshSeconds < options.accessSeconds
      || options.refreshSeconds > 604800) throw new Error('Invalid session configuration');
  }

  private reject(code = 'AUTH_SESSION_INVALID'): never {
    this.emit('auth.failed', 'WARN', { error_type: 'UnauthorizedException', error_code: code });
    throw new UnauthorizedException('Invalid session');
  }

  private async verify(token: string, type: SessionClaims['type']): Promise<SessionClaims> {
    try {
      const claims = await this.jwt.verifyAsync<SessionClaims>(token, {
        secret: type === 'access' ? this.options.accessSecret : this.options.refreshSecret,
        algorithms: ['HS256'],
      });
      if (claims.type !== type || !isUUID(claims.sub) || !isUUID(claims.sid) || !isUUID(claims.jti)
        || !Number.isSafeInteger(claims.exp)) throw new Error('Invalid session claims');
      return claims;
    } catch { return this.reject(); }
  }

  private async pair(userId: string, sid: string) {
    const [accessToken, refreshToken] = await Promise.all([
      this.jwt.signAsync({ sub: userId, sid, jti: randomUUID(), type: 'access' },
        { secret: this.options.accessSecret, algorithm: 'HS256', expiresIn: this.options.accessSeconds }),
      this.jwt.signAsync({ sub: userId, sid, jti: randomUUID(), type: 'refresh' },
        { secret: this.options.refreshSecret, algorithm: 'HS256', expiresIn: this.options.refreshSeconds }),
    ]);
    return { accessToken, refreshToken };
  }

  async issue(userId: string) {
    if (!isUUID(userId)) return this.reject();
    const sid = randomUUID();
    const pair = await this.pair(userId, sid);
    await this.store.put(userId, sid, digest(pair.refreshToken), this.options.refreshSeconds);
    return pair;
  }

  async validateAccessClaims(claims: SessionClaims): Promise<SessionClaims> {
    if (claims.type !== 'access' || !isUUID(claims.sub) || !isUUID(claims.sid) || !isUUID(claims.jti)
      || !Number.isSafeInteger(claims.exp) || claims.exp <= Date.now() / 1000) return this.reject();
    const record = await this.store.current(claims.sub);
    if (!record) return this.reject('AUTH_SESSION_MISSING');
    if (record.sid !== claims.sid) return this.reject();
    return claims;
  }

  async authenticate(accessToken: string): Promise<SessionClaims> {
    // Signature/expiry/type/shape are checked before any Redis lookup.
    const claims = await this.verify(accessToken, 'access');
    return this.validateAccessClaims(claims);
  }

  async refresh(refreshToken: string) {
    const claims = await this.verify(refreshToken, 'refresh');
    const pair = await this.pair(claims.sub, claims.sid);
    if (!await this.store.rotate(claims.sub, claims.sid, digest(refreshToken),
      digest(pair.refreshToken), this.options.refreshSeconds)) return this.reject('AUTH_REFRESH_REJECTED');
    return pair;
  }

  async logout(accessToken: string, expectedUserId?: string): Promise<void> {
    const claims = await this.verify(accessToken, 'access');
    if (expectedUserId !== undefined && claims.sub !== expectedUserId) return this.reject();
    if (!await this.store.revoke(claims.sub, claims.sid)) this.reject();
    this.emit('auth.succeeded', 'INFO', { error_code: 'AUTH_SESSION_REVOKED' });
  }
}
