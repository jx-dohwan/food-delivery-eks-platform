import { JwtService } from '@nestjs/jwt';
import { localSessionDatabase } from '../../../test/helpers/session-authority-fixture';
import { MysqlSessionAuthority } from './session-authority';
import { DataSource } from 'typeorm';
import { UnauthorizedException, ServiceUnavailableException } from '@nestjs/common';
import Redis from 'ioredis';
import { randomUUID } from 'node:crypto';
import { SessionPolicy, SessionStore, SESSION_REDIS_OPTIONS } from './session-policy';
import { CacheService } from '../cache/cache.service';
import { TokenService } from './jwt.service';
import { AccessTokenStrategy } from './accessToken.strategy';
import { JwtBlacklistGuard } from '../guard/jwtBlacklist.guard';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const options = { accessSecret: 'synthetic-access-signing-key-only', refreshSecret: 'synthetic-refresh-signing-key-only', accessSeconds: 3600, refreshSeconds: 604800 };
const port = Number(process.env.POLICY_TEST_REDIS_PORT);
const realRedis = port > 0 ? describe : describe.skip;

describe('Approved policy activation boundary', () => {
  it('is registered by the actual JWT module and checked by the access strategy', () => {
    expect(readFileSync(resolve(__dirname, 'jwt.module.ts'), 'utf8')).toContain('provide: SessionPolicy');
    expect(readFileSync(resolve(__dirname, 'accessToken.strategy.ts'), 'utf8')).toContain('validateAccessClaims(payload)');
  });
  it('rejects invalid TTL configuration before touching storage', () => {
    expect(() => new SessionPolicy(new JwtService(), {} as any, { ...options, refreshSeconds: 0 })).toThrow();
  });
});

// Only the runner's fresh loopback-only, non-persistent Redis is allowed.
// No production URL, password, default Redis host, or ambient AWS configuration.
realRedis('U06 real ephemeral local Redis contracts (NOT AWS)', () => {
  let redis: Redis;
  let store: SessionStore;
  let source: DataSource;
  let policy: SessionPolicy;
  let user: string;
  const events: unknown[][] = [];
  const emit = (...args: unknown[]) => { events.push(args); };
  const jwt = new JwtService();
  const key = () => `food-delivery/session/v1/${user}`;

  beforeAll(async () => {
    if (process.env.POLICY_TEST_EPHEMERAL !== 'true' || !Number.isInteger(port) || port > 65535)
      throw new Error('Explicit ephemeral test fixture required');
    source = await localSessionDatabase();
    redis = new Redis({ ...SESSION_REDIS_OPTIONS, host: '127.0.0.1', port, db: 15, lazyConnect: true });
    redis.on('error', () => {}); // Never print driver error text/credentials.
    await redis.connect();
  });
  beforeEach(async () => {
    user = randomUUID(); events.length = 0;
    store = new SessionStore(redis, new MysqlSessionAuthority(source, emit), emit);
    policy = new SessionPolicy(jwt, store, options, emit);
  });
  afterAll(async () => { redis?.disconnect(false); if (source?.isInitialized) await source.destroy(); });

  it('rejects a revoked signed JWT after the session key is lost, without blacklist dependence', async () => {
    const active = new TokenService(policy);
    const pair = await active.generateTokenPair(user);
    await active.revokeAllUserTokens(user, pair.accessToken);
    await redis.del(key());
    await expect(active.verifyAccessToken(pair.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(active.isTokenBlacklisted(pair.accessToken)).resolves.toBe(true);
  });

  it('stores only a hash with atomic positive TTL and authenticates the current signed session', async () => {
    const pair = await policy.issue(user);
    await expect(policy.authenticate(pair.accessToken)).resolves.toMatchObject({ sub: user });
    const raw = (await redis.get(key()))!;
    expect(raw).not.toContain(pair.refreshToken);
    expect(raw).not.toContain(pair.accessToken);
    expect(JSON.parse(raw).refresh_hash).toMatch(/^[a-f0-9]{64}$/);
    expect(await redis.ttl(key())).toBeGreaterThan(604790);
  });

  it('does not resurrect access or refresh after session data loss', async () => {
    const pair = await policy.issue(user);
    await redis.del(key());
    await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(policy.refresh(pair.refreshToken)).rejects.toBeInstanceOf(UnauthorizedException);
    expect(await redis.get(key())).toBeNull();
    expect(events.some(row => row[0] === 'auth.failed')).toBe(true);
  });

  it('allows one winner among concurrent refreshes and rejects replay', async () => {
    const first = await policy.issue(user);
    const results = await Promise.allSettled(Array.from({ length: 12 }, () => policy.refresh(first.refreshToken)));
    const wins = results.filter(row => row.status === 'fulfilled');
    expect(wins).toHaveLength(1);
    expect(results.filter(row => row.status === 'rejected')).toHaveLength(11);
    const next = (wins[0] as PromiseFulfilledResult<Awaited<ReturnType<typeof policy.refresh>>>).value;
    expect(next.refreshToken).not.toEqual(first.refreshToken);
    await expect(policy.refresh(first.refreshToken)).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(policy.refresh(next.refreshToken)).resolves.toHaveProperty('accessToken');
  });

  it('revokes access and refresh on logout and prevents an older login deleting a new session', async () => {
    const old = await policy.issue(user);
    const current = await policy.issue(user);
    await expect(policy.authenticate(old.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(policy.logout(old.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(policy.authenticate(current.accessToken)).resolves.toMatchObject({ sub: user });
    await policy.logout(current.accessToken);
    await expect(policy.authenticate(current.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
    await expect(policy.refresh(current.refreshToken)).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('rejects expired, legacy, forged, wrong-type and missing-exp claims before Redis access', async () => {
    const pair = await policy.issue(user);
    const get = jest.spyOn(redis, 'get');
    const legacy = await jwt.signAsync({ sub: user, type: 'access' }, { secret: options.accessSecret });
    const expired = await jwt.signAsync({ sub: user, sid: randomUUID(), jti: randomUUID(), type: 'access' }, { secret: options.accessSecret, expiresIn: -1 });
    const missingExp = await jwt.signAsync({ sub: user, sid: randomUUID(), jti: randomUUID(), type: 'access' }, { secret: options.accessSecret });
    for (const token of [legacy, expired, missingExp, 'synthetic.invalid.jwt', pair.refreshToken])
      await expect(policy.authenticate(token)).rejects.toBeInstanceOf(UnauthorizedException);
    expect(get).not.toHaveBeenCalled(); get.mockRestore();
  });

  it('rejects corrupt stored authentication data and expired session keys', async () => {
    const pair = await policy.issue(user);
    for (const value of ['invalid-json', 'null', '{"sid":"bad","refresh_hash":"bad"}']) {
      await redis.set(key(), value, 'EX', 60);
      await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
      await expect(policy.refresh(pair.refreshToken)).rejects.toBeInstanceOf(UnauthorizedException);
    }
    await redis.pexpire(key(), 1); await new Promise(r => setTimeout(r, 10));
    await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('bounds real Redis unresponsiveness, distinguishes 503 from 401, and records recovery without secrets', async () => {
    const pair = await policy.issue(user);
    await redis.call('CLIENT', 'PAUSE', '1600', 'ALL');
    const started = Date.now();
    await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(ServiceUnavailableException);
    expect(Date.now() - started).toBeLessThan(1500);
    await new Promise(r => setTimeout(r, 800));
    await expect(policy.authenticate(pair.accessToken)).resolves.toMatchObject({ sub: user });
    expect(events.filter(row => row[0] === 'redis.failed')).toHaveLength(1);
    expect(events.filter(row => row[0] === 'redis.ready')).toHaveLength(1);
    const serialized = JSON.stringify(events);
    for (const secret of [user, pair.accessToken, pair.refreshToken, options.accessSecret, options.refreshSecret])
      expect(serialized).not.toContain(secret);
  });

  it('fails closed while disconnected and recovers without inventing a missing session', async () => {
    const pair = await policy.issue(user);
    const ended = new Promise<void>(resolve => redis.once('end', resolve));
    redis.disconnect(false);
    await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(ServiceUnavailableException);
    await ended;
    await redis.connect();
    await redis.del(key());
    await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
    expect(await redis.get(key())).toBeNull();
  });

  it('rejects an old restored Redis authentication record using writer authority', async () => {
    const pair = await policy.issue(user);
    const saved = (await redis.get(key()))!;
    await policy.logout(pair.accessToken);
    // The same local rollback counterexample must now be rejected.
    await redis.set(key(), saved, 'EX', 60);
    await expect(policy.authenticate(pair.accessToken)).rejects.toBeInstanceOf(UnauthorizedException);
  });
});
