import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import Redis from 'ioredis';
import { DataSource } from 'typeorm';
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { EventsGateway } from '../events/events.gateway';
import { WorkloadLifecycleService } from '../core/health/workload-lifecycle.service';
import { SessionPolicy, SessionStore, SESSION_REDIS_OPTIONS } from '../core/jwt/session-policy';
import { MysqlSessionAuthority } from '../core/jwt/session-authority';
import { TokenService } from '../core/jwt/jwt.service';
import { UserRepository } from '../modules/user/repository/user.repository';
import { OrderRepository } from '../modules/order/repository/order.repository';
import { Role } from '../entities/user/user.interface';
import { OrderStatus } from '../common/type/common.interface';
import { localSessionDatabase } from '../../test/helpers/session-authority-fixture';
import { SocketWire, eventually } from '../../test/helpers/socket-client';
import * as events from '../core/logger/safe-event';
const native = process.env.POLICY_TEST_EPHEMERAL === 'true' ? describe : describe.skip;
native('P1 SQL authority + two real Nest Socket.IO listeners (local, not AWS)', () => {
  let source: DataSource; const redis: Redis[] = []; const apps: INestApplication[] = []; const policies: SessionPolicy[] = []; const clients: SocketWire[] = [];
  const jwt = new JwtService(); const users = new Map<string, any>(); let order: any;
  const observations: unknown[] = []; const logRecords: unknown[] = []; const sensitive = new Set<string>();
  const owner = { id: randomUUID(), role: Role.OWNER }; const customer = { id: randomUUID(), role: Role.CLIENT }; const driver = { id: randomUUID(), role: Role.DELIVERY };
  const options = { accessSecret: 'synthetic-p1-access-only', refreshSecret: 'synthetic-p1-refresh-only', accessSeconds: 3600, refreshSeconds: 604800 };
  const gateway = (i: number) => apps[i].get(EventsGateway);
  const scenario = (id: string, title: string, fn: () => Promise<void>) => it(`${id} ${title}`, async () => {
    const at = new Date().toISOString();
    try { await fn(); observations.push({ id, title, utc: at, result: 'PASS', method: 'actual local MySQL/Redis + Nest Socket.IO websocket' }); }
    catch (error) { observations.push({ id, title, utc: at, result: 'FAIL' }); throw error; }
  });
  async function connect(i: number, user = owner, token?: string) {
    const pair = token ? { accessToken: token } : await policies[i].issue(user.id);
    sensitive.add(pair.accessToken);
    const c = new SocketWire(apps[i].getHttpServer().address().port, pair.accessToken); clients.push(c); await c.connect();
    return { client: c, token: pair.accessToken };
  }
  async function join(i: number, client: SocketWire, room: string, event: string, data: any) {
    client.send(event, data); await eventually(() => (gateway(i).server.sockets.adapter.rooms.get(room)?.size ?? 0) > 0);
  }
  beforeAll(async () => {
    source = await localSessionDatabase();
    jest.spyOn(events, 'writeEvent').mockImplementation((e, l, f) => { logRecords.push(events.safeEvent(e, l, f)); });
    for (let i = 0; i < 2; i++) {
      const r = new Redis({ ...SESSION_REDIS_OPTIONS, host: '127.0.0.1', port: Number(process.env.POLICY_TEST_REDIS_PORT), db: 8, lazyConnect: true }); r.on('error', () => {}); redis.push(r); await r.connect(); await r.ping();
      const p = new SessionPolicy(jwt, new SessionStore(r, new MysqlSessionAuthority(source)), options); policies.push(p);
      const mod = await Test.createTestingModule({ providers: [EventsGateway, WorkloadLifecycleService,
        { provide: TokenService, useValue: new TokenService(p) },
        { provide: UserRepository, useValue: { findOneByFilters: async (f: any) => users.get(f.id) ?? null } },
        { provide: OrderRepository, useValue: { findOneWithOmitNotJoinedPropsOrThrow: async () => order } }] }).compile();
      const app = mod.createNestApplication({ logger: false }); await app.listen(0, '127.0.0.1'); apps.push(app);
    }
  });
  beforeEach(() => {
    users.clear(); for (const u of [owner, customer, driver]) { users.set(u.id, { ...u }); sensitive.add(u.id); }
    order = { id: randomUUID(), customerId: customer.id, driverId: driver.id, status: OrderStatus.PickedUp, restaurant: { ownerId: owner.id } };
  });
  afterEach(async () => {
    for (const c of clients.splice(0)) c.close();
    await new Promise(r => setTimeout(r, 30));
    const serialized = JSON.stringify(logRecords);
    for (const s of sensitive) expect(serialized).not.toContain(s);
  });
  afterAll(async () => {
    if (process.env.P1_EVIDENCE_FILE) writeFileSync(process.env.P1_EVIDENCE_FILE, JSON.stringify({ scope: 'LOCAL_REAL_SOCKET_SQL_REDIS_NOT_AWS', tests: observations, sensitive_values_absent_in_structured_logs: true }, null, 2));
    for (const app of apps) await app.close(); for (const r of redis) r.disconnect(false); if (source?.isInitialized) await source.destroy(); jest.restoreAllMocks();
  });
  scenario('W01', 'private owner push is delivered normally on each WAS and blocked after logout on either WAS', async () => {
    const first = await connect(0); const second = await connect(1, owner, first.token); const room = `${Role.OWNER}:${owner.id}`;
    for (const [i, c] of [[0, first.client], [1, second.client]] as const) await join(i, c, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    for (let i = 0; i < 2; i++) await gateway(i).emitAuthorizedRoom(room, 'newPendingOrder', { total: 100 });
    await eventually(() => first.client.events.length === 1 && second.client.events.length === 1);
    await policies[0].logout(first.token);
    for (let i = 0; i < 2; i++) await gateway(i).emitAuthorizedRoom(room, 'newPendingOrder', { total: 200 });
    await eventually(() => first.client.disconnected && second.client.disconnected);
    expect(first.client.events).toHaveLength(1); expect(second.client.events).toHaveLength(1);
  });
  scenario('W02', 'restored Redis state cannot authorize push after durable logout', async () => {
    const c = await connect(0); const room = `${Role.OWNER}:${owner.id}`; await join(0, c.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    const key = `food-delivery/session/v1/${owner.id}`; const saved = (await redis[0].dumpBuffer(key))!;
    await policies[1].logout(c.token); await redis[0].restore(key, 60000, saved, 'REPLACE');
    await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', { total: 100 }); await eventually(() => c.client.disconnected); expect(c.client.events).toHaveLength(0);
  });
  scenario('W03', 'new login revokes old room subscriptions but preserves the new session', async () => {
    const old = await connect(0); const room = `${Role.OWNER}:${owner.id}`; await join(0, old.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    const next = await connect(1); await join(1, next.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', {}); await gateway(1).emitAuthorizedRoom(room, 'newPendingOrder', {});
    await eventually(() => old.client.disconnected && next.client.events.length === 1); expect(old.client.events).toHaveLength(0);
  });
  scenario('W04', 'real driver action uses recipient authorization and preserves legitimate location updates', async () => {
    const c = await connect(0, customer); const d = await connect(0, driver); const room = `order:${order.id}`;
    await join(0, c.client, room, 'joinOrderRoom', { orderId: order.id });
    d.client.send('updateDriverLocation', { orderId: order.id, lat: 37, lng: 127 });
    await eventually(() => c.client.events.some(([e]) => e === 'driverLocation'));
    await policies[1].logout(c.token); d.client.send('updateDriverLocation', { orderId: order.id, lat: 38, lng: 128 });
    await eventually(() => c.client.disconnected); expect(c.client.events.filter(([e]) => e === 'driverLocation')).toHaveLength(1);
  });
  scenario('W05', 'changed order authorization is checked again before a server push', async () => {
    const c = await connect(0, customer); const room = `order:${order.id}`; await join(0, c.client, room, 'joinOrderRoom', { orderId: order.id });
    order.customerId = randomUUID(); await gateway(0).emitAuthorizedRoom(room, 'orderUpdate', { status: 'synthetic' });
    await eventually(() => c.client.disconnected); expect(c.client.events).toHaveLength(0);
  });
  scenario('W06', 'SQL authority outage suppresses private push and closes the recipient', async () => {
    const c = await connect(0); const room = `${Role.OWNER}:${owner.id}`; await join(0, c.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    await source.destroy();
    try { await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', {}); await eventually(() => c.client.disconnected); expect(c.client.events).toHaveLength(0); }
    finally { await source.initialize(); }
  });
  scenario('W07', 'Redis state loss suppresses private push without recreating a session', async () => {
    const c = await connect(0); const room = `${Role.OWNER}:${owner.id}`; await join(0, c.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    await redis[0].del(`food-delivery/session/v1/${owner.id}`); await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', {});
    await eventually(() => c.client.disconnected); expect(c.client.events).toHaveLength(0);
  });
  scenario('W08', 'token expiry disconnects a subscribed socket', async () => {
    const issued = await policies[0].issue(owner.id); const claims = jwt.decode(issued.accessToken) as any; delete claims.exp; delete claims.iat;
    const token = jwt.sign(claims, { secret: options.accessSecret, expiresIn: 1 });
    const c = await connect(0, owner, token); const room = `${Role.OWNER}:${owner.id}`; await join(0, c.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    await eventually(() => c.client.disconnected, 2500); await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', {}); expect(c.client.events).toHaveLength(0);
  });
  scenario('W09', 'a real Redis disconnect suppresses private push while unrelated valid recipients recover', async () => {
    const c = await connect(0); const room = `${Role.OWNER}:${owner.id}`; await join(0, c.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    const ended = new Promise<void>(r => redis[0].once('end', r)); redis[0].disconnect(false); await ended;
    try { await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', {}); await eventually(() => c.client.disconnected); expect(c.client.events).toHaveLength(0); }
    finally { await redis[0].connect(); }
    const current = await connect(0); await join(0, current.client, room, 'joinUserRoom', { userId: owner.id, role: owner.role });
    await gateway(0).emitAuthorizedRoom(room, 'newPendingOrder', {}); await eventually(() => current.client.events.length === 1);
  });

  scenario('W10', 'one revoked recipient never blocks a distinct authorized recipient in the same order room', async () => {
    const c = await connect(0, customer); const o = await connect(0, owner); const room = `order:${order.id}`;
    await join(0, c.client, room, 'joinOrderRoom', { orderId: order.id });
    o.client.send('joinOrderRoom', { orderId: order.id }); await eventually(() => gateway(0).server.sockets.adapter.rooms.get(room)?.size === 2);
    await policies[1].logout(c.token); await gateway(0).emitAuthorizedRoom(room, 'orderUpdate', { status: 'synthetic' });
    await eventually(() => c.client.disconnected && o.client.events.length === 1);
    expect(c.client.events).toHaveLength(0); expect(o.client.disconnected).toBe(false);
  });

});
