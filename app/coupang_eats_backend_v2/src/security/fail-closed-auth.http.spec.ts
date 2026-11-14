/** Actual controllers/services/JwtModule/CacheModule/guards + real Redis.
 * Business persistence, SELECT1 and email delivery are isolated local doubles.
 * Two Nest listeners have separate Redis clients against one ephemeral fixture.
 */
import { Global, Module, type INestApplication, NotFoundException } from '@nestjs/common';
import { APP_GUARD, APP_FILTER, APP_INTERCEPTOR } from '@nestjs/core';
import { MODULE_METADATA } from '@nestjs/common/constants';
import { Test } from '@nestjs/testing';
import { ThrottlerModule, getStorageToken } from '@nestjs/throttler';
import { JwtService } from '@nestjs/jwt';
import Redis from 'ioredis';
import request from 'supertest';
import { randomUUID, randomBytes } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { CoreModule } from '../core/core.module';
import { JwtModule } from '../core/jwt/jwt.module';
import { SessionStore } from '../core/jwt/session-policy';
import { SessionAuthority } from '../core/jwt/session-authority';
import { TokenService } from '../core/jwt/jwt.service';
import { ConfigModule } from '../core/config/config.module';
import { MoinConfigService } from '../core/config/config.service';
import { RedisClientKey, CacheServiceKey } from '../core/cache/cache.interface';
import { CacheModule } from '../core/cache/cache.module';
import { UserRepositoryModule } from '../modules/user/repository/user-repository.module';
import { UserRepository } from '../modules/user/repository/user.repository';
import { AuthController } from '../modules/auth/auth.controller';
import { AuthService } from '../modules/auth/auth.service';
import { AuthTxService } from '../modules/auth/auth.tx.service';
import { UserController } from '../modules/user/user.controller';
import { UserService } from '../modules/user/user.service';
import { User } from '../entities/user/user.entity';
import { Role } from '../entities/user/user.interface';
import { HashModule } from '../core/hash/hash.module';
import { BcryptService } from '../core/hash/bcrypt.service';
import { NOTIFICATION_SERVICE } from '../core/notification/notification.interface';
import { LoggerService } from '../core/logger/logger.service';
import { RequestContextService } from '../core/cls/cls.service';
import * as events from '../core/logger/safe-event';
import { rateLimitOptions } from '../core/rate-limit/rate-limit.policy';
import { MemoryRateLimitStorage } from '../core/rate-limit/rate-limit.storage';
import { HealthModule } from '../core/health/health.module';
import { MetricsModule } from '../core/metrics/metrics.module';
import { MetricsService } from '../core/metrics/metrics.service';
import { configureMetrics } from '../core/metrics/configure-metrics';
import { configureWorkloadLifecycle } from '../core/health/configure-workload-lifecycle';
import { setNestApp } from '../setNestApp';
import { DataSource } from 'typeorm';
import { localSessionDatabase } from '../../test/helpers/session-authority-fixture';
let sessionSource: DataSource;

const port = Number(process.env.POLICY_TEST_REDIS_PORT);
const native = port > 0 ? describe : describe.skip;
const accessSecret = 'synthetic-native-access-signing-only';
const refreshSecret = 'synthetic-native-refresh-signing-only';
let signingKeys = { access: accessSecret, refresh: refreshSecret };
const password = 'SynthPass123!';
const users = new Map<string, User>();
let records: unknown[] = [];
let welcomeToken = '';
const userRepo = {
  findOneByFilters: async (f: { id?: string; email?: string }) => [...users.values()].find(u => f.id ? u.id === f.id : u.email === f.email) ?? null,
  findOneOrThrow: async (f: { email: string }) => { const u = [...users.values()].find(u => u.email === f.email); if (!u) throw new NotFoundException(); return u; },
  findByIdOrThrow: async (id: string) => { const u = users.get(id); if (!u) throw new NotFoundException(); return u; },
  save: async (u: User) => { users.set(u.id, u); return u; },
};
const config = {
  getJwtConfig: () => ({ JWT_ACCESS_SECRET: signingKeys.access, JWT_REFRESH_SECRET: signingKeys.refresh, JWT_ACCESS_EXPIRATION: '1h', JWT_REFRESH_EXPIRATION: '7d' }),
  getRedisConfig: () => ({ HOST: '127.0.0.1', PORT: port, TLS: false }),
};
@Global()
@Module({ providers: [{ provide: MoinConfigService, useValue: config }], exports: [MoinConfigService] })
class LocalConfigModule {}
@Global()
@Module({ providers: [{ provide: UserRepository, useValue: userRepo },
  { provide: DataSource, useFactory: () => sessionSource }], exports: [UserRepository, DataSource] })
class LocalUserRepositoryModule {}

native('U06 real Nest HTTP + ephemeral Redis (not AWS)', () => {
  let apps: INestApplication[] = [];
  let admin: Redis;
  let hashed: string;
  let first: User;
  let second: User;
  let limits = new MemoryRateLimitStorage();
  const observations: unknown[] = [];
  let details: Record<string, unknown> = {};
  const jwt = new JwtService();
  const sensitive = new Set<string>([password, accessSecret, refreshSecret]);
  const key = (u = first) => `food-delivery/session/v1/${u.id}`;
  const logger = { event: (e: any, l: any, f: any) => records.push(events.safeEvent(e, l, f)), info: () => {}, warn: () => {}, error: () => {} };
  const scenario = (id: string, title: string, fn: () => Promise<void>) => it(`${id} ${title}`, async () => {
    const start = new Date().toISOString(); details = {};
    try { await fn(); observations.push({ id, title, started_utc: start, result: 'PASS', details, method: 'Nest HTTP + actual isolated local Redis' }); }
    catch (error) { observations.push({ id, title, started_utc: start, result: 'FAIL', details, method: 'Nest HTTP + actual isolated local Redis' }); throw error; }
  }, 20000);
  const remember = (r: any) => {
    const token = r.body.data.accessToken as string;
    const cookie = (r.headers['set-cookie'] as string[])[0].split(';')[0];
    const refresh = cookie.slice('refreshToken='.length);
    sensitive.add(token); sensitive.add(refresh);
    return { access: token, cookie, refresh };
  };
  const login = async (app = 0, u = first) => remember(await request(apps[app].getHttpServer()).post('/auth/sign-in').send({ email: u.email, password }).expect(200));
  const profile = (access: string, app = 0, u = first) => request(apps[app].getHttpServer()).get(`/users/${u.id}`).set('Authorization', `Bearer ${access}`);
  const refresh = (cookie: string, app = 0) => request(apps[app].getHttpServer()).post('/auth/refresh').set('Cookie', cookie);
  const logout = (access: string, app = 0) => request(apps[app].getHttpServer()).post('/auth/sign-out').set('Authorization', `Bearer ${access}`);

  async function createApp() {
    const providers = Reflect.getMetadata(MODULE_METADATA.PROVIDERS, CoreModule).filter((p: any) => [APP_GUARD, APP_FILTER, APP_INTERCEPTOR].includes(p.provide));
      const module = await Test.createTestingModule({
        imports: [JwtModule, CacheModule, HashModule, HealthModule, MetricsModule, ThrottlerModule.forRoot(rateLimitOptions())],
        controllers: [AuthController, UserController],
        providers: [AuthService, UserService, ...providers,
          { provide: AuthTxService, useValue: { createUserOrThrow: async (dto: any, hash: string) => {
            const u = Object.assign(new User(), { id: randomUUID(), ...dto, password: hash, verified: false }); users.set(u.id, u);
          } } },
          { provide: NOTIFICATION_SERVICE, useValue: { sendWelcomeNotification: async (_email: string, _name: string, token: string) => { welcomeToken = token; sensitive.add(token); } } },
          { provide: LoggerService, useValue: logger },
          { provide: RequestContextService, useValue: { getRequestId: () => undefined } },
          { provide: DataSource, useFactory: () => sessionSource },
        ],
      }).overrideModule(ConfigModule).useModule(LocalConfigModule)
        .overrideModule(UserRepositoryModule).useModule(LocalUserRepositoryModule)
        .overrideProvider(LoggerService).useValue(logger)
        .overrideProvider(getStorageToken()).useValue({ increment: (k: string, ttl: number, limit: number) => limits.increment(k, ttl, limit) }).compile();
      const app = module.createNestApplication({ logger: false });
      setNestApp(app); configureMetrics(app); configureWorkloadLifecycle(app);
      await app.listen(0, '127.0.0.1');
      const client = app.get<Redis>(RedisClientKey);
      if (client.status !== 'ready') await new Promise<void>(r => client.once('ready', r));
      return app;
  }

  beforeAll(async () => {
    if (process.env.POLICY_TEST_EPHEMERAL !== 'true') throw new Error('Ephemeral fixture approval required');
    sessionSource = await localSessionDatabase();
    admin = new Redis({ host: '127.0.0.1', port, db: 0, lazyConnect: true, enableOfflineQueue: false });
    admin.on('error', () => {}); await admin.connect();
    hashed = await new BcryptService().hash(password);
    jest.spyOn(events, 'writeEvent').mockImplementation((event, level, fields) => { records.push(events.safeEvent(event, level, fields)); });
    for (let i = 0; i < 2; i++) apps.push(await createApp());
  });
  beforeEach(() => {
    users.clear(); records = []; welcomeToken = ''; limits = new MemoryRateLimitStorage();
    first = Object.assign(new User(), { id: randomUUID(), email: `${randomUUID()}@example.test`, name: 'Synthetic', role: Role.CLIENT, password: hashed, verified: true });
    second = Object.assign(new User(), { id: randomUUID(), email: `${randomUUID()}@example.test`, name: 'Other', role: Role.CLIENT, password: hashed, verified: true });
    for (const u of [first, second]) { users.set(u.id, u); sensitive.add(u.email); sensitive.add(u.id); }
  });
  afterEach(() => {
    const output = JSON.stringify(records);
    for (const value of sensitive) expect(output.includes(value)).toBe(false);
  });
  afterAll(async () => {
    if (process.env.U06_HTTP_EVIDENCE_FILE) writeFileSync(process.env.U06_HTTP_EVIDENCE_FILE, JSON.stringify({ scope: 'LOCAL_REAL_HTTP_REDIS_NOT_AWS', tests: observations }, null, 2));
    for (const app of apps) await app.close();
    admin?.disconnect(false); if (sessionSource?.isInitialized) await sessionSource.destroy(); jest.restoreAllMocks();
  });

  scenario('T01', 'login creates a hash-only TTL session before returning tokens', async () => {
    const pair = await login(); const raw = (await admin.get(key()))!;
    expect(raw.includes(pair.refresh)).toBe(false); expect(await admin.ttl(key())).toBeGreaterThan(604790);
    await profile(pair.access).expect(200);
    const claims = jwt.decode(pair.access) as any; expect(claims.exp - claims.iat).toBe(3600);
    const r = jwt.decode(pair.refresh) as any; expect(r.exp - r.iat).toBe(604800); expect(claims.sid).toBe(r.sid);
  });
  scenario('T02', 'protected HTTP reads a current session once despite duplicate guard decorators', async () => {
    const pair = await login(); const spies = apps.map(a => jest.spyOn(a.get(SessionStore), 'current'));
    await profile(pair.access).expect(200);
    expect(spies.reduce((n, s) => n + s.mock.calls.length, 0)).toBe(1);
    spies.forEach(s => s.mockRestore());
  });
  scenario('T03', 'logged-out access stays rejected even after authentication key loss', async () => {
    const p = await login(); await logout(p.access).expect(200); await admin.del(key());
    await profile(p.access).expect(401);
  });
  scenario('T04', 'logged-out refresh cannot issue tokens', async () => {
    const p = await login(); await logout(p.access).expect(200); await refresh(p.cookie).expect(401);
  });
  scenario('T05', 'missing or corrupt session rejects access and refresh without recreating it', async () => {
    const p = await login(); await admin.del(key()); await profile(p.access).expect(401); await refresh(p.cookie).expect(401);
    expect(await admin.exists(key())).toBe(0);
    await admin.set(key(), 'invalid-json', 'EX', 10); await profile(p.access).expect(401); await refresh(p.cookie).expect(401);
    const next = await login(); await admin.pexpire(key(), 1); await new Promise(r => setTimeout(r, 10));
    await profile(next.access).expect(401); await refresh(next.cookie).expect(401);
  });
  scenario('T06', 'real Redis unresponsiveness returns 503, does not become 401 or success', async () => {
    const p = await login(); await admin.call('CLIENT', 'PAUSE', '1600', 'ALL');
    const started = Date.now(); await profile(p.access).expect(503); details = { status: 503, elapsed_ms: Date.now() - started, fault: 'actual Redis CLIENT PAUSE' }; await new Promise(r => setTimeout(r, 850));
    expect(records.some((r: any) => r.event === 'redis.failed')).toBe(true);
    const client = apps[0].get<Redis>(RedisClientKey); const end = new Promise<void>(r => client.once('end', r));client.disconnect(false);await end;
    const failed = await refresh(p.cookie).expect(503); expect(failed.headers['set-cookie']).toBeUndefined();
    await client.connect();
  });
  scenario('T07', 'recovered Redis accepts retained state but never reconstructs lost sessions', async () => {
    const p = await login(); const client = apps[1].get<Redis>(RedisClientKey);
    const end = new Promise<void>(r => client.once('end', r)); client.disconnect(false); await end;
    await profile(p.access).expect(503);
    await request(apps[1].getHttpServer()).get('/health/ready').expect(503);
    await request(apps[1].getHttpServer()).get('/health/live').expect(200);
    await client.connect(); await profile(p.access).expect(200);
    details = { disconnected: 503, ready_while_disconnected: 503, live_while_disconnected: 200, recovered: 200 };
    await admin.del(key()); await profile(p.access).expect(401);
  });
  scenario('T08', 'two actual HTTP listeners rotate concurrently with one winner', async () => {
    const p = await login(); const replies = await Promise.all(Array.from({ length: 8 }, (_, i) => refresh(p.cookie, i % 2)));
    expect(replies.filter(r => r.status === 200)).toHaveLength(1);
    expect(replies.filter(r => r.status === 401)).toHaveLength(7);
    details = { listeners: 2, requests: 8, success_200: replies.filter(r => r.status === 200).length, rejected_401: replies.filter(r => r.status === 401).length };
    const winner = remember(replies.find(r => r.status === 200)!); await profile(winner.access, 1).expect(200);
  });
  scenario('T09', 'consumed refresh is rejected without revoking the winner', async () => {
    const p = await login(); const next = remember(await refresh(p.cookie).expect(200));
    await refresh(p.cookie, 1).expect(401); await profile(next.access).expect(200); await refresh(next.cookie).expect(200);
  });
  scenario('T10', 'login storage failure never returns tokens or a success cookie', async () => {
    const client = apps[0].get<Redis>(RedisClientKey); const end = new Promise<void>(r => client.once('end', r)); client.disconnect(false); await end;
    const result = await request(apps[0].getHttpServer()).post('/auth/sign-in').send({ email: first.email, password }).expect(503);
    expect(result.headers['set-cookie']).toBeUndefined(); expect(JSON.stringify(result.body)).not.toContain('accessToken');
    await client.connect();
    await admin.call('CLIENT', 'PAUSE', '1600', 'ALL');
    const timed = await request(apps[0].getHttpServer()).post('/auth/sign-in').send({ email: first.email, password }).expect(503);
    expect(timed.headers['set-cookie']).toBeUndefined(); expect(JSON.stringify(timed.body)).not.toContain('accessToken');
    await new Promise(r => setTimeout(r, 850)); await login();
    details = { disconnected_login: 503, delayed_ack_login: 503, success_cookie_on_failure: false, relogin: 200 };
  });
  scenario('T11', 'expired, forged, wrong-type, missing-claim JWTs fail before business access', async () => {
    const p = await login(); const c = jwt.decode(p.access) as any; const base = { sub: c.sub, sid: c.sid, jti: c.jti, type: 'access' };
    for (const token of [jwt.sign(base, { secret: accessSecret, expiresIn: -1 }), jwt.sign(base, { secret: 'different-synthetic-key', expiresIn: '1h' }), p.refresh,
      jwt.sign({ sub: c.sub, type: 'access' }, { secret: accessSecret, expiresIn: '1h' })]) await profile(token).expect(401);
    users.delete(first.id); await profile(p.access).expect(401);
  });
  scenario('T12', 'public signup/email validation and health/metrics remain accessible', async () => {
    const email = `${randomUUID()}@example.test`; sensitive.add(email);
    await request(apps[0].getHttpServer()).post('/auth/sign-up').send({ email, password, name: 'Synthetic', role: Role.CLIENT }).expect(201);
    await request(apps[0].getHttpServer()).post('/auth/sign-in').send({ email, password }).expect(401);
    await request(apps[0].getHttpServer()).get('/auth/verify-email').query({ token: welcomeToken }).expect(200);
    await request(apps[0].getHttpServer()).post('/auth/sign-in').send({ email, password }).expect(200);
    for (const path of ['/health/live', '/health/startup', '/health/ready', '/metrics']) await request(apps[0].getHttpServer()).get(path).expect(200);
  });
  scenario('T13', 'user/session ownership and BOLA remain enforced', async () => {
    const a = await login(); const b = await login(1, second);
    await profile(a.access, 0, second).expect(403);
    const ac = jwt.decode(a.access) as any, bc = jwt.decode(b.access) as any;
    const mixed = jwt.sign({ sub: second.id, sid: ac.sid, jti: bc.jti, type: 'access' }, { secret: accessSecret, expiresIn: '1h' });
    await profile(mixed, 1, second).expect(401); await logout(a.access).expect(200); await profile(b.access, 1, second).expect(200);
    const current = await login(); await profile(a.access).expect(401); await profile(current.access).expect(200);
  });
  scenario('T14', 'legacy signed tokens have no compatibility bypass', async () => {
    const old = jwt.sign({ sub: first.id, type: 'access' }, { secret: accessSecret, expiresIn: '1h' });
    const oldRefresh = jwt.sign({ sub: first.id, type: 'refresh' }, { secret: refreshSecret, expiresIn: '7d' });
    await profile(old).expect(401); await refresh(`refreshToken=${oldRefresh}`).expect(401); expect(await admin.exists(key())).toBe(0);
  });
  scenario('T15', 'logout/refresh races cannot reactivate a logged-out session', async () => {
    const p = await login(); const [out, rotated] = await Promise.all([logout(p.access, 0), refresh(p.cookie, 1)]);
    expect(out.status).toBe(200); expect([200, 401]).toContain(rotated.status);
    details = { logout_status: out.status, refresh_status: rotated.status, session_recreated: false }; expect(await admin.exists(key())).toBe(0);
    await profile(p.access).expect(401); await refresh(p.cookie).expect(401);
    if (rotated.status === 200) { const q = remember(rotated); await profile(q.access).expect(401); await refresh(q.cookie).expect(401); }
    const next = await login(); await profile(next.access).expect(200);
  });
  scenario('O02', 'uncertain refresh commit never returns tokens and does not roll back an older credential', async () => {
    const p = await login(); const before = JSON.parse((await admin.get(key()))!).refresh_hash;
    await admin.call('CLIENT', 'PAUSE', '1600', 'ALL');
    const response = await refresh(p.cookie).expect(503);
    expect(response.headers['set-cookie']).toBeUndefined(); expect(JSON.stringify(response.body)).not.toContain('accessToken');
    await new Promise(r => setTimeout(r, 850));
    const after = JSON.parse((await admin.get(key()))!).refresh_hash;
    expect(typeof after).toBe('string');
    if (after !== before) await refresh(p.cookie).expect(401);
    const next = await login(); await profile(next.access).expect(200);
    details = { timeout_status: 503, committed_after_timeout: after !== before, old_refresh_status: 401, compensation_restore_attempted: false, relogin: 200 };
  });
  scenario('O01', 'HTTP 401 and Redis 503 remain distinct metrics without identity labels', async () => {
    const p = await login(); await admin.del(key()); await profile(p.access).expect(401);
    const client = apps[1].get<Redis>(RedisClientKey); const end = new Promise<void>(r => client.once('end', r));client.disconnect(false);await end;
    const valid = await login(); await profile(valid.access).expect(503); await client.connect();
    const text = await apps[0].get(MetricsService).registry.metrics();
    expect(text).toMatch(/food_delivery_http_requests_total\{[^\n]*status_code="401"/);
    expect(text).toMatch(/food_delivery_http_requests_total\{[^\n]*status_code="503"/);
    expect(text).not.toMatch(/user_id=|session_id=|jti=|sid=/);
  });
  scenario('O03', 'unexpected authentication dependency failure remains a sanitized server error', async () => {
    const p = await login(); const marker = 'SYNTHETIC_PRIVATE_DB_ERROR'; sensitive.add(marker);
    const find = jest.spyOn(userRepo, 'findOneByFilters').mockRejectedValueOnce(new Error(marker));
    try {
      const result = await profile(p.access).expect(500);
      expect(JSON.stringify(result.body)).not.toContain(marker);
      details = { dependency_error_status: 500, misclassified_as_401: false, raw_error_exposed: false };
    } finally { find.mockRestore(); }
  });
  scenario('R01', 'Redis DUMP/RESTORE cannot revive a logged-out HTTP session', async () => {
    const pair = await login(); const dumped = (await admin.dumpBuffer(key()))!;
    await logout(pair.access).expect(200);
    await admin.restore(key(), 60000, dumped, 'REPLACE');
    await profile(pair.access, 1).expect(401); await refresh(pair.cookie, 1).expect(401);
    details = { restored: 'actual Redis per-key DUMP/RESTORE, not AWS Snapshot', protected: 401, refresh: 401 };
  });
  scenario('R02', 'Redis refresh-hash rollback cannot reuse a consumed refresh', async () => {
    const pair = await login(); const dumped = (await admin.dumpBuffer(key()))!;
    const next = remember(await refresh(pair.cookie, 1).expect(200));
    await admin.restore(key(), 60000, dumped, 'REPLACE');
    await refresh(pair.cookie, 0).expect(401); await profile(next.access, 1).expect(200);
    // Fail closed when SQL and Redis disagree; do not auto-repair from a token.
    await refresh(next.cookie, 1).expect(401); const recovered = await login(); await profile(recovered.access).expect(200);
    details = { consumed_refresh_after_restore: 401, current_access_same_sid: 200, divergent_refresh: 401, relogin: 200 };
  });
  scenario('R03', 'restoring an older login cannot replace the SQL-authorized current sid', async () => {
    const old = await login(); const dumped = (await admin.dumpBuffer(key()))!; const next = await login(1);
    await admin.restore(key(), 60000, dumped, 'REPLACE');
    await profile(old.access).expect(401); await refresh(old.cookie).expect(401);
    await profile(next.access).expect(401); await login();
  });
  scenario('R04', 'a deliberately stale real Redis replica cannot reauthorize after promotion', async () => {
    const replica = new Redis({ host: '127.0.0.1', port: Number(process.env.POLICY_TEST_REDIS_REPLICA_PORT) });
    const active = apps[0].get<Redis>(RedisClientKey); const originalPort = active.options.port;
    try {
      await replica.call('REPLICAOF', process.env.POLICY_TEST_REDIS_PRIMARY_HOST!, '6379');
      const pair = await login(1); const saved = await admin.get(key()); const deadline = Date.now() + 12000;
      while (await replica.get(key()) !== saved) { if (Date.now() > deadline) throw new Error('Replica sync timed out'); await new Promise(r => setTimeout(r, 50)); }
      // Freeze a real synchronized replica before logout, then switch clients to
      // it after logout. Models a stale promoted endpoint, not AWS failover timing.
      await replica.call('REPLICAOF', 'NO', 'ONE'); await logout(pair.access, 1).expect(200);
      const ended = new Promise<void>(r => active.once('end', r)); active.disconnect(false); await ended;
      active.options.port = Number(process.env.POLICY_TEST_REDIS_REPLICA_PORT); await active.connect();
      expect(await replica.get(key())).toBe(saved); await profile(pair.access).expect(401); await refresh(pair.cookie).expect(401);
      details = { real_replica_sync_and_promotion: true, stale_key_present: true, protected: 401, refresh: 401, AWS_automatic_failover: 'NOT_TESTED' };
    } finally {
      const ended = new Promise<void>(r => active.once('end', r)); active.disconnect(false); await ended; active.options.port = originalPort; await active.connect(); replica.disconnect(false);
    }
  });
  scenario('R05', 'real SQL pool outage denies protected HTTP and login with 503', async () => {
    const pair = await login(); await sessionSource.destroy();
    try {
      await profile(pair.access).expect(503);
      const result = await request(apps[0].getHttpServer()).post('/auth/sign-in').send({ email: first.email, password }).expect(503);
      expect(result.headers['set-cookie']).toBeUndefined(); expect(JSON.stringify(result.body)).not.toContain('accessToken');
    } finally { await sessionSource.initialize(); }
    await profile(pair.access).expect(200); details = { SQL_pool_unavailable: 503, recovered: 200 };
  });
  scenario('R06', 'uncertain SQL refresh commit cannot be compensated by restored Redis state', async () => {
    const pair = await login(); const saved = (await admin.get(key()))!; const authority = apps[0].get(SessionAuthority);
    const original = authority.rotate.bind(authority);
    const fault = jest.spyOn(authority, 'rotate').mockImplementationOnce(async (...args) => { await original(...args); throw new (require('@nestjs/common').ServiceUnavailableException)('Synthetic lost acknowledgement'); });
    try {
      const result = await refresh(pair.cookie).expect(503); expect(result.headers['set-cookie']).toBeUndefined();
    } finally { fault.mockRestore(); }
    await admin.set(key(), saved, 'EX', 60); await refresh(pair.cookie, 1).expect(401); await login();
    details = { fault: 'local injected response loss after real SQL commit', refresh_status: 503, retry_after_redis_restore: 401 };
  });
  scenario('R07', 'SQL revocation survives a lost logout acknowledgement and SQL reconnect', async () => {
    const pair = await login(); const saved = (await admin.get(key()))!; const authority = apps[0].get(SessionAuthority);
    const original = authority.revoke.bind(authority);
    const fault = jest.spyOn(authority, 'revoke').mockImplementationOnce(async (...args) => { await original(...args); throw new (require('@nestjs/common').ServiceUnavailableException)('Synthetic lost acknowledgement'); });
    try { await logout(pair.access).expect(503); } finally { fault.mockRestore(); }
    await admin.set(key(), saved, 'EX', 60); await sessionSource.destroy(); await sessionSource.initialize();
    await profile(pair.access, 1).expect(401); await refresh(pair.cookie, 1).expect(401);
    details = { logout_acknowledgement: 503, writer_reconnected: true, stale_access: 401, stale_refresh: 401 };
  });

  const snapshot = async () => ({ sql: (await sessionSource.query('SELECT user_id, sid, refresh_hash, expires_at_ms FROM auth_session_state WHERE user_id = ?', [first.id]))[0], redis: (await admin.dumpBuffer(key()))! });
  const restoreSQL = async (saved: any) => sessionSource.query('INSERT INTO auth_session_state (user_id,sid,refresh_hash,expires_at_ms) VALUES (?,?,?,?) ON DUPLICATE KEY UPDATE sid=VALUES(sid),refresh_hash=VALUES(refresh_hash),expires_at_ms=VALUES(expires_at_ms)', [saved.sql.user_id,saved.sql.sid,saved.sql.refresh_hash,saved.sql.expires_at_ms]);
  const restoreBoth = async (saved: any) => { await restoreSQL(saved); await admin.restore(key(), 60000, saved.redis, 'REPLACE'); };
  async function restartWithKeys(keys: { access: string; refresh: string }) {
    // Actual closed-app maintenance boundary; only synthetic fixture secrets.
    const old = apps.splice(0); for (const app of old) await app.close();
    signingKeys = keys; sensitive.add(keys.access); sensitive.add(keys.refresh);
    for (let i = 0; i < 2; i++) apps.push(await createApp());
  }
  scenario('S01', 'documents the joint SQL+Redis rollback boundary without external invalidation', async () => {
    const old = await login(); const saved = await snapshot();
    const next = remember(await refresh(old.cookie).expect(200)); await refresh(old.cookie).expect(401);
    await logout(next.access).expect(200); await profile(old.access).expect(401);
    await restoreSQL(saved); await profile(old.access).expect(401); // Redis still missing.
    await sessionSource.query('DELETE FROM auth_session_state WHERE user_id = ?', [first.id]);
    await admin.restore(key(), 60000, saved.redis, 'REPLACE'); await profile(old.access).expect(401); // SQL still revoked.
    await restoreBoth(saved); await profile(old.access).expect(200); await refresh(old.cookie).expect(200);
    details = { only_SQL_restored: 401, only_Redis_restored: 401, both_restored_old_access: 200, both_restored_consumed_refresh: 200, classification: 'KNOWN_TRUST_BOUNDARY_REPRODUCED_NOT_SECURITY_PASS', AWS_PITR: 'NOT_EXECUTED' };
  });
  scenario('S02', 'closing old listeners and switching BOTH external signing keys rejects restored tokens', async () => {
    const old = await login(); const saved = await snapshot(); await logout(old.access).expect(200); await restoreBoth(saved);
    await restartWithKeys({ access: randomBytes(32).toString('hex'), refresh: randomBytes(32).toString('hex') });
    expect(await admin.exists(key())).toBe(1); // Do not solve this by deleting state.
    await profile(old.access).expect(401); await profile(old.access, 1).expect(401);
    await refresh(old.cookie).expect(401); await refresh(old.cookie, 1).expect(401);
    const current = await login(); await profile(current.access).expect(200); await refresh(current.cookie, 1).expect(200);
    details = { external_keys: 'synthetic local config only', old_listeners_closed: true, restored_state_kept: true, old_access_both_listeners: 401, old_refresh_both_listeners: 401, relogin: 200, operational_policy: 'REQUIRES_APPROVAL_NOT_ACTIVATED' };
  });
  scenario('S03', 'access-only key rotation is insufficient because the restored refresh can issue a new access', async () => {
    const old = await login(); const saved = await snapshot(); await logout(old.access).expect(200); await restoreBoth(saved);
    await restartWithKeys({ access: randomBytes(32).toString('hex'), refresh: signingKeys.refresh });
    await profile(old.access).expect(401); await refresh(old.cookie).expect(200);
    await restartWithKeys({ access: randomBytes(32).toString('hex'), refresh: randomBytes(32).toString('hex') });
    await restoreBoth(saved); await profile(old.access).expect(401); await refresh(old.cookie).expect(401);
    details = { access_only_rotation_old_access: 401, unchanged_refresh_key_old_refresh: 200, classification: 'INCOMPLETE_RECOVERY_COUNTEREXAMPLE', both_keys_changed_old_access: 401, both_keys_changed_old_refresh: 401 };
  });

});
