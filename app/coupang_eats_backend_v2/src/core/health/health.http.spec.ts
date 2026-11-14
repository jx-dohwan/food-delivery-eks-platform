import { Controller, Get, type INestApplication } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { SkipThrottle, ThrottlerModule } from '@nestjs/throttler';
import type { Server } from 'node:http';
import type { Request } from 'express';
import request from 'supertest';
import { DataSource } from 'typeorm';
import { CacheServiceKey } from '../cache/cache.interface';
import { Public } from '../decorator/public.decorator';
import { AccessTokenGuard } from '../guard/accessToken.guard';
import { JwtBlacklistGuard } from '../guard/jwtBlacklist.guard';
import { TokenService } from '../jwt/jwt.service';
import { LoggerService } from '../logger/logger.service';
import { SafeConsoleLogger } from '../logger/safe-console.logger';
import { RequestContextService } from '../cls/cls.service';
import {
  IpRateLimitGuard,
  ApiRateLimitGuard,
} from '../rate-limit/rate-limit.guard';
import { configureWorkloadLifecycle } from './configure-workload-lifecycle';
import { HealthController } from './health.controller';
import { HealthService } from './health.service';
import { WorkloadLifecycleService } from './workload-lifecycle.service';

let startedSlow: () => void;
let finishSlow: () => void;
@Public()
@SkipThrottle({ baseline: true, default: true })
@Controller('reliability-test')
class TestController {
  @Get('fast')
  fast() {
    return { status: 'ok' };
  }
  @Get('slow')
  async slow() {
    startedSlow();
    await new Promise<void>((resolve) => {
      finishSlow = resolve;
    });
    return { status: 'finished' };
  }
}

describe('Health and native Nest shutdown HTTP integration (no DB/AWS)', () => {
  let app: INestApplication<Server>;
  let lifecycle: WorkloadLifecycleService;
  let server: Server;
  let closed: boolean;
  const query = jest.fn();
  const pingReady = jest.fn();
  const blacklist = jest.fn();

  beforeEach(async () => {
    jest.spyOn(SafeConsoleLogger.prototype, 'log').mockImplementation(() => {});
    query.mockReset().mockResolvedValue([{ 1: 1 }]);
    pingReady.mockReset().mockResolvedValue(undefined);
    blacklist.mockClear();
    closed = false;
    const module = await Test.createTestingModule({
      imports: [
        ThrottlerModule.forRoot([
          { name: 'baseline', ttl: 60_000, limit: 1 },
          { name: 'default', ttl: 60_000, limit: 1 },
        ]),
      ],
      controllers: [HealthController, TestController],
      providers: [
        HealthService,
        WorkloadLifecycleService,
        { provide: DataSource, useValue: { isInitialized: true, query } },
        { provide: CacheServiceKey, useValue: { pingReady } },
        { provide: TokenService, useValue: { isTokenBlacklisted: blacklist } },
        { provide: LoggerService, useValue: {} },
        { provide: RequestContextService, useValue: {} },
        { provide: APP_GUARD, useClass: IpRateLimitGuard },
        { provide: APP_GUARD, useClass: AccessTokenGuard },
        { provide: APP_GUARD, useClass: ApiRateLimitGuard },
      ],
    }).compile();
    app = module.createNestApplication<INestApplication<Server>>({
      logger: false,
    });
    const enableHooks = jest.spyOn(app, 'enableShutdownHooks');
    configureWorkloadLifecycle(app);
    expect(enableHooks).toHaveBeenCalledWith(['SIGTERM', 'SIGINT']);
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer();
    lifecycle = app.get(WorkloadLifecycleService);
  });
  afterEach(async () => {
    if (!closed) await app?.close();
    jest.restoreAllMocks();
  });

  it('serves public startup/live/readiness without JWT or throttling', async () => {
    for (let i = 0; i < 4; i += 1) {
      for (const path of ['live', 'startup', 'ready']) {
        const response = await request(server)
          .get(`/health/${path}`)
          .expect(200);
        expect(response.body).toEqual({ status: 'ok' });
      }
    }
    expect(blacklist).not.toHaveBeenCalled();
    expect(query).toHaveBeenCalledTimes(1);
  });

  it('keeps liveness independent from DB/Redis and hides failure details', async () => {
    query.mockRejectedValue(new Error('PASSWORD jwt redis.private db.private'));
    pingReady.mockRejectedValue(new Error('COOKIE_SECRET'));
    await request(server).get('/health/live').expect(200);
    const response = await request(server)
      .get('/health/ready')
      .set('Authorization', 'Bearer VERY_SECRET_JWT')
      .set('Cookie', 'refreshToken=COOKIE_SECRET')
      .expect(503);
    expect(response.body).toEqual({ status: 'unavailable' });
    expect(response.text).not.toMatch(
      /PASSWORD|JWT|COOKIE_SECRET|private|stack/,
    );
    expect(blacklist).not.toHaveBeenCalled();
  });

  it('rejects remote drain even if forwarded headers spoof loopback', () => {
    const controller = app.get(HealthController);
    expect(() =>
      controller.drain({
        socket: { remoteAddress: '10.0.10.30' },
        headers: { 'x-forwarded-for': '127.0.0.1' },
      } as unknown as Request),
    ).toThrow('Not allowed');
    expect(lifecycle.isDraining).toBe(false);
  });

  it('marks readiness unavailable and blocks new requests while remaining live', async () => {
    await request(server).post('/health/drain').expect(200);
    await request(server).get('/health/ready').expect(503);
    await request(server).get('/health/live').expect(200);
    await request(server)
      .get('/reliability-test/fast')
      .expect(503)
      .expect('Connection', 'close');
  });

  it('native app.close waits for the in-flight request before closing HTTP', async () => {
    const started = new Promise<void>((resolve) => {
      startedSlow = resolve;
    });
    const pending = request(server)
      .get('/reliability-test/slow')
      .then((r) => r);
    await started;
    lifecycle.beginDrain();
    const closing = app.close();
    await request(server).get('/reliability-test/fast').expect(503);
    finishSlow();
    expect((await pending).status).toBe(200);
    await closing;
    closed = true;
    expect(server.listening).toBe(false);
  });
});
