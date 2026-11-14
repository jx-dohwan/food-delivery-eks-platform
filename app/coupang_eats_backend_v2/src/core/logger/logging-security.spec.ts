import { BadRequestException, UnauthorizedException } from '@nestjs/common';
import type { ArgumentsHost, ExecutionContext } from '@nestjs/common';
import type { Request, Response } from 'express';
import { EventEmitter } from 'events';
import { firstValueFrom, throwError } from 'rxjs';
import type { WinstonLogger } from 'nest-winston';
import { ConfigService } from '@nestjs/config';
import { LoggerService } from './logger.service';
import { RequestLoggerMiddleware } from '../middleware/requestLogger.middleware';
import { ErrorFilter } from '../filter/error.filter';
import { ErrorInterceptor } from '../interceptor/error.interceptor';
import { MoinConfigService } from '../config/config.service';
import { Env, type Configurations } from '../config';
import { RequestContextService } from '../cls/cls.service';
import { DevEmailCaptureService } from '../notification/dev-email-capture.service';
import { EmailService } from '../notification/email.service';
import { AwsSesService } from '../aws/aws-ses.service';
import { JwtBlacklistGuard } from '../guard/jwtBlacklist.guard';
import { Reflector } from '@nestjs/core';
import { TokenService } from '../jwt/jwt.service';

describe('actual request/error log boundaries', () => {
  const winston = {
    log: jest.fn(),
    debug: jest.fn(),
    verbose: jest.fn(),
    warn: jest.fn(),
    error: jest.fn(),
  };
  const config = {
    getAppConfig: () => ({ ENV: Env.prod, NAME: 'test' }),
  } as unknown as MoinConfigService;
  const cls = {
    getRequestId: () => '00000000-0000-4000-8000-000000000001',
  } as unknown as RequestContextService;
  const logger = new LoggerService(
    winston as unknown as WinstonLogger,
    {},
    config,
  );
  const logs = () =>
    JSON.stringify(
      Object.values(winston).map((fn) => fn.mock.calls as unknown),
    );
  const request = (url: string) =>
    ({
      method: 'POST',
      originalUrl: `${url}?token=QUERY_SECRET&status=OPEN`,
      url,
      route: { path: url },
      body: {
        email: 'tester@example.com',
        password: 'SUPER_SECRET_PASSWORD',
        users: [{ refreshToken: 'ARRAY_SECRET' }],
      },
      query: { token: 'QUERY_SECRET', status: 'OPEN' },
      headers: {
        authorization: 'Bearer VERY_SECRET_JWT',
        cookie: 'refreshToken=COOKIE_SECRET',
        'x-request-id': '00000000-0000-4000-8000-000000000001',
      },
    }) as unknown as Request;
  const response = () =>
    Object.assign(new EventEmitter(), {
      statusCode: 200,
      setHeader: jest.fn(),
      status: jest.fn().mockReturnThis(),
      json: jest.fn(),
      getHeaders: () => ({
        'set-cookie': ['refreshToken=RESPONSE_COOKIE_SECRET'],
      }),
    });
  const assertSafe = () =>
    expect(logs()).not.toMatch(
      /SUPER_SECRET_PASSWORD|ARRAY_SECRET|VERY_SECRET_JWT|COOKIE_SECRET|QUERY_SECRET|ERROR_SECRET|SQL_SECRET|tester@example.com/,
    );

  beforeEach(() => jest.clearAllMocks());

  it.each([
    '/auth/sign-in',
    '/auth/sign-up',
    '/auth/refresh',
    '/auth/sign-out',
    '/auth/verify-email',
  ])('keeps completion metadata and discards auth values at %s', (url) => {
    const req = request(url);
    const res = response();
    const next = jest.fn();
    new RequestLoggerMiddleware(logger, cls).use(
      req,
      res as unknown as Response,
      next,
    );
    res.emit('finish');
    assertSafe();
    expect(logs()).not.toMatch(/"body"|"query"|"headers"/);
    expect(logs()).toContain('00000000-0000-4000-8000-000000000001');
    expect(logs()).toContain(url);
    expect(logs()).toContain('duration');
    expect(next).toHaveBeenCalledTimes(1);
    expect((req.body as Record<string, unknown>).password).toBe(
      'SUPER_SECRET_PASSWORD',
    );
  });

  it('discards ordinary body fields on the actual middleware output', () => {
    const req = request('/restaurants');
    req.body = {
      restaurantId: '123',
      status: 'OPEN',
      password: 'SUPER_SECRET_PASSWORD',
    };
    new RequestLoggerMiddleware(logger, cls).use(
      req,
      response() as unknown as Response,
      jest.fn(),
    );
    assertSafe();
    expect(logs()).not.toContain('restaurantId');
    expect(logs()).not.toContain('OPEN');
  });

  it.each([
    new BadRequestException({
      message: ['ERROR_SECRET'],
      password: 'ERROR_SECRET',
    }),
    new UnauthorizedException('ERROR_SECRET'),
    Object.assign(new Error('SQL_SECRET'), {
      query: 'SQL_SECRET',
      parameters: ['SUPER_SECRET_PASSWORD'],
      code: 'ER_DUP_ENTRY',
    }),
  ])(
    'protects validation/authentication/database errors without mutating the HTTP response',
    (error) => {
      const req = request('/auth/sign-in');
      const res = response();
      const host = {
        switchToHttp: () => ({ getRequest: () => req, getResponse: () => res }),
      } as unknown as ArgumentsHost;
      new ErrorFilter(logger, config).catch(error, host);
      assertSafe();
      expect(logs()).toContain('00000000-0000-4000-8000-000000000001');
      expect(res.json).toHaveBeenCalledTimes(1);
    },
  );

  it('does not fall back to a raw circular request body on unexpected exceptions', () => {
    const req = request('/orders');
    const body = req.body as Record<string, unknown>;
    body.self = body;
    const res = response();
    new ErrorFilter(logger, config).catch(new Error('ERROR_SECRET'), {
      switchToHttp: () => ({ getRequest: () => req, getResponse: () => res }),
    } as unknown as ArgumentsHost);
    assertSafe();
    expect(logs()).not.toContain('[CIRCULAR]');
    expect(logs()).toContain('http.exception');
  });

  it('also protects the currently unregistered ErrorInterceptor', async () => {
    const ctx = {
      switchToHttp: () => ({
        getRequest: () => request('/auth/refresh'),
        getResponse: () => response(),
      }),
    } as unknown as ExecutionContext;
    await firstValueFrom(
      new ErrorInterceptor(logger).intercept(ctx, {
        handle: () => throwError(() => new Error('ERROR_SECRET')),
      }),
    );
    assertSafe();
  });

  it.each(['info', 'debug', 'verbose', 'warn', 'error'] as const)(
    'redacts at logger level %s including headers and token responses',
    (level) => {
      logger[level](
        'test',
        {
          headers: {
            Authorization: 'Bearer VERY_SECRET_JWT',
            Cookie: 'COOKIE_SECRET',
            'Set-Cookie': 'RESPONSE_COOKIE_SECRET',
          },
          response: { accessToken: 'ARRAY_SECRET' },
          nested: { password: 'SUPER_SECRET_PASSWORD' },
        },
        'Operation',
      );
      assertSafe();
      logger[level]('test', 'UNLABELED_SECRET', 'Operation');
      expect(logs()).not.toContain('UNLABELED_SECRET');
    },
  );

  it('never logs a revoked token from JwtBlacklistGuard', async () => {
    const guard = new JwtBlacklistGuard(
      { getAllAndOverride: () => false } as unknown as Reflector,
      {
        isTokenBlacklisted: () => Promise.resolve(true),
      } as unknown as TokenService,
      logger,
      cls,
    );
    const ctx = {
      getHandler: () => ({}),
      getClass: () => ({}),
      switchToHttp: () => ({ getRequest: () => request('/orders') }),
    } as unknown as ExecutionContext;
    await expect(guard.canActivate(ctx)).rejects.toThrow(UnauthorizedException);
    assertSafe();
    expect(logs()).not.toContain('VERY_SECRET_JWT');
  });

  it('does not log the email-verification URL/token when SES is skipped', async () => {
    const service = new EmailService(
      logger,
      {} as AwsSesService,
      new ConfigService<Configurations>({
        APP: { BASE_URL: 'https://example.com' },
        AWS: { SES_SENDER_EMAIL: '' },
      }),
      { capture: () => false } as unknown as DevEmailCaptureService,
    );
    await service.sendWelcomeNotification(
      'tester@example.com',
      'Private Name',
      'EMAIL_VERIFICATION_SECRET',
    );
    assertSafe();
    expect(logs()).not.toContain('EMAIL_VERIFICATION_SECRET');
    expect(logs()).not.toContain('@example.com');
  });
});
