import {
  Controller,
  Get,
  Post,
  HttpException,
  type INestApplication,
} from '@nestjs/common';
import { APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { SkipThrottle, ThrottlerModule } from '@nestjs/throttler';
import type { Server } from 'node:http';
import request from 'supertest';
import { Public } from '../decorator/public.decorator';
import { AccessTokenGuard } from '../guard/accessToken.guard';
import { JwtBlacklistGuard } from '../guard/jwtBlacklist.guard';
import { TokenService } from '../jwt/jwt.service';
import { LoggerService } from '../logger/logger.service';
import { RequestContextService } from '../cls/cls.service';
import {
  IpRateLimitGuard,
  ApiRateLimitGuard,
} from '../rate-limit/rate-limit.guard';
import { ApiResponseInterceptor } from '../interceptor/apiResponse.interceptor';
import { configureWorkloadLifecycle } from '../health/configure-workload-lifecycle';
import { WorkloadLifecycleService } from '../health/workload-lifecycle.service';
import { SafeConsoleLogger } from '../logger/safe-console.logger';
import { configureMetrics } from './configure-metrics';
import { MetricsModule } from './metrics.module';
import { MetricsService } from './metrics.service';

@Public()
@SkipThrottle({ baseline: true, default: true })
@Controller()
class TrafficController {
  @Get('orders/:id')
  order() {
    return { status: 'ok' };
  }
  @Post('orders/:id')
  update() {
    return { status: 'ok' };
  }
  @Get('failure')
  failure() {
    throw new HttpException('Unavailable', 503);
  }
  @Get('health/live')
  live() {
    return { status: 'ok' };
  }
}

describe('Internal Prometheus metrics HTTP integration (no AWS/DB)', () => {
  let app: INestApplication<Server>;
  let server: Server;
  let metrics: MetricsService;
  const blacklist = jest.fn();

  beforeEach(async () => {
    jest.spyOn(SafeConsoleLogger.prototype, 'log').mockImplementation(() => {});
    blacklist.mockClear();
    const module = await Test.createTestingModule({
      imports: [
        MetricsModule,
        ThrottlerModule.forRoot([
          { name: 'baseline', ttl: 60_000, limit: 1 },
          { name: 'default', ttl: 60_000, limit: 1 },
        ]),
      ],
      controllers: [TrafficController],
      providers: [
        WorkloadLifecycleService,
        { provide: TokenService, useValue: { isTokenBlacklisted: blacklist } },
        { provide: LoggerService, useValue: {} },
        { provide: RequestContextService, useValue: {} },
        { provide: APP_GUARD, useClass: IpRateLimitGuard },
        { provide: APP_GUARD, useClass: AccessTokenGuard },
        { provide: APP_GUARD, useClass: ApiRateLimitGuard },
        { provide: APP_INTERCEPTOR, useClass: ApiResponseInterceptor },
      ],
    }).compile();
    app = module.createNestApplication<INestApplication<Server>>({
      logger: false,
    });
    configureMetrics(app);
    configureWorkloadLifecycle(app);
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer();
    metrics = app.get(MetricsService);
  });

  afterEach(async () => {
    await app.close();
    jest.restoreAllMocks();
  });

  it('exposes Prometheus text and process metrics without JWT, wrapping or 429', async () => {
    for (let i = 0; i < 3; i++) {
      const response = await request(server).get('/metrics').expect(200);
      expect(response.headers['content-type']).toMatch(
        /text\/plain;.*version=0\.0\.4/,
      );
      expect(response.text).toContain('process_cpu_user_seconds_total');
      expect(response.text).toContain('process_resident_memory_bytes');
      expect(response.text).toContain('nodejs_eventloop_lag_seconds');
      expect(response.text).not.toContain('"success":');
    }
    expect(blacklist).not.toHaveBeenCalled();
  });

  it('counts HTTP responses and records histogram/count/sum with template labels', async () => {
    await request(server).get('/orders/123').expect(200);
    await request(server).get('/orders/124').expect(200);
    const { text } = await request(server).get('/metrics');
    expect(text).toContain(
      'food_delivery_http_requests_total{method="GET",route="/orders/:id",status_code="200"} 2',
    );
    expect(text).toMatch(
      /food_delivery_http_request_duration_seconds_count\{[^\n]+\} 2/,
    );
    expect(text).toContain(
      'food_delivery_http_request_duration_seconds_bucket',
    );
    expect(text).toContain('food_delivery_http_request_duration_seconds_sum');
    expect(text).not.toMatch(/\/orders\/(?:123|124)/);
  });

  it('records 5xx and folds unmatched paths into one bounded route', async () => {
    await request(server).get('/failure').expect(503);
    await request(server).get('/missing/secret-one').expect(404);
    await request(server).get('/missing/secret-two').expect(404);
    const { text } = await request(server).get('/metrics');
    expect(text).toContain('route="/failure",status_code="503"} 1');
    expect(text).toContain('route="unmatched",status_code="404"} 2');
    expect(text).not.toMatch(/secret-one|secret-two/);
  });

  it('never exports request IDs, PII, credentials, bodies, headers or query values', async () => {
    await request(server)
      .post(
        '/orders/private-order-id?email=tester@example.com&token=QUERY_SECRET',
      )
      .set('Authorization', 'Bearer VERY_SECRET_JWT')
      .set('Cookie', 'refreshToken=COOKIE_SECRET')
      .set('X-Request-ID', 'REQUEST_ID_SECRET')
      .send({
        userId: 'USER_ID_SECRET',
        password: 'SUPER_SECRET_PASSWORD',
        email: 'tester@example.com',
      })
      .expect(201);
    const { text } = await request(server).get('/metrics');
    expect(text).not.toMatch(
      /private-order-id|tester@|QUERY_SECRET|VERY_SECRET_JWT|COOKIE_SECRET|REQUEST_ID_SECRET|USER_ID_SECRET|SUPER_SECRET_PASSWORD/,
    );
    expect(text).not.toMatch(
      /(?:userId|email|authorization|cookie|request_id)=/i,
    );
  });

  it('excludes health and self-scrapes from business rate and latency', async () => {
    await request(server).get('/health/live').expect(200);
    await request(server).get('/health/ready').expect(404);
    await request(server).get('/metrics').expect(200);
    const { text } = await request(server).get('/metrics');
    expect(text).not.toMatch(/food_delivery_http_requests_total\{/);
    expect(text).not.toMatch(
      /food_delivery_http_request_duration_seconds_count\{/,
    );
  });

  it('isolates recording and scrape failures from business requests and secrets', async () => {
    jest.spyOn(metrics, 'record').mockImplementationOnce(() => {
      throw new Error('SECRET_RECORDING');
    });
    await request(server).get('/orders/123').expect(200);
    jest
      .spyOn(metrics.registry, 'metrics')
      .mockRejectedValueOnce(new Error('PASSWORD_SECRET'));
    const response = await request(server).get('/metrics').expect(503);
    expect(response.text).toBe('Metrics unavailable\n');
    await request(server).get('/orders/124').expect(200);
  });

  it('allows final scrapes during drain but rejects business traffic and closes cleanly', async () => {
    app.get(WorkloadLifecycleService).beginDrain();
    await request(server).get('/metrics').expect(200);
    await request(server).get('/orders/123').expect(503);
    const { text } = await request(server).get('/metrics').expect(200);
    // Draining rejects before routing, so the route remains bounded "unmatched".
    expect(text).toContain('route="unmatched",status_code="503"} 1');
  });
});
