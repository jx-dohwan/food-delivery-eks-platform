import { SessionUnitStore } from '../../../test/helpers/session-unit-store';
import { SessionPolicy } from '../jwt/session-policy';
import { INestApplication, UnauthorizedException } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import {
  ThrottlerModule,
  getStorageToken,
  type ThrottlerStorage,
} from '@nestjs/throttler';
import request from 'supertest';
import type { Server } from 'node:http';
import type { WinstonLogger } from 'nest-winston';
import { AppController } from '../../app.controller';
import { AuthController } from '../../modules/auth/auth.controller';
import { AuthService } from '../../modules/auth/auth.service';
import { UserController } from '../../modules/user/user.controller';
import { UserService } from '../../modules/user/user.service';
import { OrderController } from '../../modules/order/order.controller';
import { OrderService } from '../../modules/order/order.service';
import { UploadController } from '../../modules/upload/upload.controller';
import { UserRepository } from '../../modules/user/repository/user.repository';
import { AwsS3Service } from '../aws/aws-s3.service';
import { User } from '../../entities/user/user.entity';
import { Role } from '../../entities/user/user.interface';
import { LoggerService } from '../logger/logger.service';
import { MoinConfigService } from '../config/config.service';
import { Env } from '../config';
import { RequestContextService } from '../cls/cls.service';
import { TokenType } from '../jwt/jwt.interface';
import { TokenService } from '../jwt/jwt.service';
import { AccessTokenStrategy } from '../jwt/accessToken.strategy';
import { RefreshTokenStrategy } from '../jwt/refreshToken.strategy';
import { AccessTokenGuard } from '../guard/accessToken.guard';
import { JwtBlacklistGuard } from '../guard/jwtBlacklist.guard';
import { ApiResponseInterceptor } from '../interceptor/apiResponse.interceptor';
import { ErrorFilter } from '../filter/error.filter';
import { IpRateLimitGuard, ApiRateLimitGuard } from './rate-limit.guard';
import { RATE_LIMITS, rateLimitOptions } from './rate-limit.policy';
import { MemoryRateLimitStorage } from './rate-limit.storage';
import { RateLimitProxySettings } from './client-ip';
import { setNestApp } from '../../setNestApp';

describe('application rate limits on real HTTP/authentication boundaries', () => {
  let app: INestApplication;
  let server: Server;
  let store = new MemoryRateLimitStorage();
  const increment = jest.fn((key: string, ttl: number, limit: number) =>
    store.increment(key, ttl, limit),
  );
  const storage: ThrottlerStorage = { increment };
  const idA = '00000000-0000-4000-8000-000000000001';
  const idB = '00000000-0000-4000-8000-000000000002';
  const userA = Object.assign(new User(), {
    id: idA,
    name: 'A',
    email: 'A@example.com',
    role: Role.CLIENT,
    verified: true,
  });
  const userB = Object.assign(new User(), {
    id: idB,
    name: 'B',
    email: 'B@example.com',
    role: Role.CLIENT,
    verified: true,
  });
  const secret = 'rate-limit-tests-access-secret';
  const jwt = new JwtService();
  const sessions = new SessionUnitStore();
  const policy = new SessionPolicy(jwt, sessions as any, { accessSecret: secret, refreshSecret: 'rate-refresh-tests', accessSeconds: 3600, refreshSeconds: 604800 });
  const token = (id: string) =>
    jwt.sign(sessions.claims(id), { secret, expiresIn: '1h' });
  const winston = {
    log: jest.fn(),
    debug: jest.fn(),
    verbose: jest.fn(),
    warn: jest.fn(),
    error: jest.fn(),
  };
  const config = {
    getAppConfig: () => ({ ENV: Env.prod, NAME: 'test' }),
    getJwtConfig: () => ({
      JWT_ACCESS_SECRET: secret,
      JWT_REFRESH_SECRET: 'rate-refresh-tests',
    }),
  } as unknown as MoinConfigService;
  const logger = new LoggerService(
    winston as unknown as WinstonLogger,
    {},
    config,
  );
  const auth = {
    signIn: jest.fn(() =>
      Promise.reject(new UnauthorizedException('Invalid credentials')),
    ),
    signUp: jest.fn(() => Promise.resolve()),
    verifyEmail: jest.fn(() => Promise.resolve()),
  };
  const createOrder = jest.fn(() => Promise.resolve({ id: 'created' }));
  const upload = jest.fn();

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      imports: [ThrottlerModule.forRoot(rateLimitOptions())],
      controllers: [
        AppController,
        AuthController,
        UserController,
        OrderController,
        UploadController,
      ],
      providers: [
        AccessTokenStrategy,
        RefreshTokenStrategy,
        { provide: AuthService, useValue: auth },
        {
          provide: UserService,
          useValue: {
            getUser: (id: string) =>
              Promise.resolve(id === idA ? userA : userB),
            updateUser: (id: string) =>
              Promise.resolve(id === idA ? userA : userB),
          },
        },
        { provide: OrderService, useValue: { createOrder } },
        {
          provide: AwsS3Service,
          useValue: { uploadImage: upload, uploadImages: upload },
        },
        {
          provide: UserRepository,
          useValue: {
            findOneByFilters: (filter: { id: string }) =>
              Promise.resolve(
                filter.id === idA ? userA : filter.id === idB ? userB : null,
              ),
          },
        },
        {
          provide: TokenService,
          useValue: new TokenService(policy),
        },
        { provide: LoggerService, useValue: logger },
        { provide: MoinConfigService, useValue: config },
        {
          provide: RequestContextService,
          useValue: { getRequestId: () => 'rate-security-test' },
        },
        { provide: APP_GUARD, useClass: IpRateLimitGuard },
        { provide: APP_GUARD, useClass: AccessTokenGuard },
        { provide: APP_GUARD, useClass: ApiRateLimitGuard },
        { provide: APP_FILTER, useClass: ErrorFilter },
        { provide: APP_INTERCEPTOR, useClass: ApiResponseInterceptor },
      ],
    })
      .overrideProvider(getStorageToken())
      .useValue(storage)
      .compile();
    app = module.createNestApplication({ logger: false });
    // Loopback stands in for the Web Pod in this isolated HTTP test only.
    setNestApp(
      app,
      new RateLimitProxySettings(['10.0.0.0/24'], ['127.0.0.1/32', '::1/128']),
    );
    await app.init();
    // Keep one loopback listener for the 600-request quota test; avoid a new
    // ephemeral listen/close race on every Supertest request.
    await app.listen(0, '127.0.0.1');
    server = app.getHttpServer() as Server;
  });
  afterAll(async () => {
    await app?.close();
  });
  beforeEach(() => {
    store = new MemoryRateLimitStorage();
    sessions.rows.clear();
    jest.clearAllMocks();
  });

  const login = (ip = '203.0.113.1', prefix = '198.51.100.1') =>
    request(server)
      .post('/auth/sign-in')
      .set('X-Forwarded-For', `${prefix}, ${ip}, 10.0.0.20`)
      .send({ email: 'tester@example.com', password: 'SUPER_SECRET_PASSWORD' });

  it('returns normal 401s up to the sign-in threshold, then a safe 429 with Retry-After', async () => {
    for (let i = 0; i < RATE_LIMITS.signIn.limit; i++)
      await login().expect(401);
    const response = await login().expect(429);
    expect(auth.signIn).toHaveBeenCalledTimes(RATE_LIMITS.signIn.limit);
    expect(response.body as unknown).toEqual(
      expect.objectContaining({
        statusCode: 429,
        message: 'Too many requests. Please try again later.',
      }),
    );
    expect(Number(response.headers['retry-after'])).toBeGreaterThan(0);
    expect(JSON.stringify(response.body as unknown)).not.toMatch(
      /password|SUPER_SECRET|tester@example.com|stack|tracker|key/,
    );
  });
  it('does not block independent client B when client A exceeds its limit', async () => {
    for (let i = 0; i <= RATE_LIMITS.signIn.limit; i++) await login();
    await login('203.0.113.2').expect(401);
  });
  it('does not permit changing the spoofed XFF prefix to reset a counter', async () => {
    for (let i = 0; i < RATE_LIMITS.signIn.limit; i++)
      await login('203.0.113.1', `198.51.100.${i}`).expect(401);
    await login('203.0.113.1', '1.2.3.4').expect(429);
  });
  it('counts all guessed account emails in one IP bucket', async () => {
    for (let i = 0; i <= RATE_LIMITS.signIn.limit; i++) {
      const response = await request(server)
        .post('/auth/sign-in')
        .set('X-Forwarded-For', '203.0.113.3, 10.0.0.20')
        .send({ email: `guess${i}@example.com`, password: 'SECRET' });
      expect(response.status).toBe(i === RATE_LIMITS.signIn.limit ? 429 : 401);
    }
  });
  it('limits signup and email verification independently', async () => {
    for (let i = 0; i < RATE_LIMITS.signUp.limit; i++)
      await request(server)
        .post('/auth/sign-up')
        .send({
          email: `signup${i}@example.com`,
          name: 'User',
          password: 'ValidPass123!',
          role: Role.CLIENT,
        })
        .expect(201);
    await request(server)
      .post('/auth/sign-up')
      .send({
        email: 'extra@example.com',
        name: 'User',
        password: 'ValidPass123!',
        role: Role.CLIENT,
      })
      .expect(429);
    for (let i = 0; i < RATE_LIMITS.verifyEmail.limit; i++)
      await request(server)
        .get('/auth/verify-email?token=EMAIL_SECRET')
        .expect(200);
    await request(server)
      .get('/auth/verify-email?token=EMAIL_SECRET')
      .expect(429);
  });
  it('limits invalid refresh cookies before expensive refresh verification', async () => {
    for (let i = 0; i < RATE_LIMITS.refresh.limit; i++)
      await request(server)
        .post('/auth/refresh')
        .set('Cookie', 'refreshToken=COOKIE_SECRET')
        .expect(401);
    await request(server)
      .post('/auth/refresh')
      .set('Cookie', 'refreshToken=COOKIE_SECRET')
      .expect(429);
  });
  it('isolates verified users behind one IP and keeps A limited across IP changes', async () => {
    for (let i = 0; i < RATE_LIMITS.profile.limit; i++)
      await request(server)
        .patch('/users/profile')
        .auth(token(idA), { type: 'bearer' })
        .set('X-Forwarded-For', `203.0.113.${i + 1}, 10.0.0.20`)
        .send({ name: 'A' })
        .expect(200);
    await request(server)
      .patch('/users/profile')
      .auth(token(idA), { type: 'bearer' })
      .set('X-Forwarded-For', '203.0.113.100, 10.0.0.20')
      .send({ name: 'A' })
      .expect(429);
    await request(server)
      .patch('/users/profile')
      .auth(token(idB), { type: 'bearer' })
      .set('X-Forwarded-For', '203.0.113.100, 10.0.0.20')
      .send({ name: 'B' })
      .expect(200);
  });
  it('does not reset a user quota by rotating JWTs', async () => {
    for (let i = 0; i <= RATE_LIMITS.profile.limit; i++) {
      const access = jwt.sign(
        sessions.claims(idA),
        { secret, expiresIn: '1h' },
      );
      await request(server)
        .patch('/users/profile')
        .auth(access, { type: 'bearer' })
        .send({ name: 'A' })
        .expect(i === RATE_LIMITS.profile.limit ? 429 : 200);
    }
  });
  it('limits orders before business mutation', async () => {
    for (let i = 0; i < RATE_LIMITS.orderCreate.limit; i++)
      await request(server)
        .post('/orders')
        .auth(token(idA), { type: 'bearer' })
        .send({ restaurantId: idB, items: [] })
        .expect(201);
    await request(server)
      .post('/orders')
      .auth(token(idA), { type: 'bearer' })
      .send({ restaurantId: idB, items: [] })
      .expect(429);
    expect(createOrder).toHaveBeenCalledTimes(RATE_LIMITS.orderCreate.limit);
  });
  it.each([
    ['/uploads', RATE_LIMITS.upload.limit],
    ['/uploads/batch', RATE_LIMITS.uploadBatch.limit],
  ] as const)(
    'limits %s before upload interceptors and AWS calls',
    async (path, limit) => {
      for (let i = 0; i < limit; i++)
        await request(server)
          .post(path)
          .auth(token(idA), { type: 'bearer' })
          .expect(400);
      await request(server)
        .post(path)
        .auth(token(idA), { type: 'bearer' })
        .expect(429);
      expect(upload).not.toHaveBeenCalled();
    },
  );
  it('exempts both actual health endpoints without even accessing storage', async () => {
    for (let i = 0; i < 100; i++)
      await request(server)
        .get(i % 2 ? '/health' : '/')
        .expect(200);
    expect(increment).not.toHaveBeenCalled();
  });
  it('allows sign-in again after window expiration', async () => {
    const now = Date.now();
    const clock = jest.spyOn(Date, 'now').mockReturnValue(now);
    try {
      for (let i = 0; i < RATE_LIMITS.signIn.limit; i++)
        await login().expect(401);
      await login().expect(429);
      clock.mockReturnValue(now + RATE_LIMITS.signIn.ttl + 1);
      await login().expect(401);
    } finally {
      clock.mockRestore();
    }
  });
  it('applies the aggregate IP budget before authentication across different routes', async () => {
    for (let i = 0; i < 600; i++)
      await request(server).get(`/users/${idA}`).expect(401);
    await request(server).get(`/users/${idB}`).expect(429);
    await request(server).get('/health').expect(200);
  });
  it('keeps credentials out of storage keys, actual error logs and 429 JSON', async () => {
    const access = token(idA);
    for (let i = 0; i <= RATE_LIMITS.signIn.limit; i++) {
      const response = await login()
        .set('Authorization', `Bearer ${access}`)
        .set('Cookie', 'refreshToken=COOKIE_SECRET');
      expect(JSON.stringify(response.body as unknown)).not.toContain(access);
    }
    const logs = JSON.stringify(
      Object.values(winston).map((fn) => fn.mock.calls as unknown),
    );
    const keys = increment.mock.calls.map((call) => call[0]);
    expect(logs).not.toMatch(
      /SUPER_SECRET_PASSWORD|COOKIE_SECRET|tester@example.com/,
    );
    expect(logs).not.toContain(access);
    expect(keys.every((key) => /^[a-f0-9]{64}$/.test(key))).toBe(true);
  });
});
