import {
  requestForLog,
  sanitizeForLog,
  sanitizeLogUrl,
  REDACTED,
} from './log-sanitizer';
import type { Request } from 'express';

describe('log redaction policy', () => {
  it.each([
    [
      { email: 'tester@example.com', password: 'SUPER_SECRET_PASSWORD' },
      'SUPER_SECRET_PASSWORD',
    ],
    [{ user: { password: 'NESTED_SECRET' } }, 'NESTED_SECRET'],
    [{ users: [{ password: 'ARRAY_SECRET' }] }, 'ARRAY_SECRET'],
    [{ Authorization: 'Bearer VERY_SECRET_JWT' }, 'VERY_SECRET_JWT'],
    [{ Cookie: 'refreshToken=COOKIE_SECRET' }, 'COOKIE_SECRET'],
    [
      { 'Set-Cookie': ['refreshToken=RESPONSE_COOKIE_SECRET'] },
      'RESPONSE_COOKIE_SECRET',
    ],
  ])('redacts credential case %#', (input, secret) => {
    const output = JSON.stringify(sanitizeForLog(input));
    expect(output).not.toContain(secret);
    expect(output).toContain(REDACTED);
  });

  it.each([
    'passwordConfirm',
    'currentPassword',
    'newPassword',
    'accessToken',
    'refreshToken',
    'token',
    'jwt',
    'authorization',
    'cookie',
    'set-cookie',
    'clientSecret',
    'secret',
    'secretKey',
    'apiKey',
    'api_key',
    'DB_PASSWORD',
    'JWT_ACCESS_SECRET',
    'JWT_REFRESH_SECRET',
    'Refresh_Token',
  ])('covers sensitive key %s regardless of case', (key) => {
    expect(sanitizeForLog({ [key.toUpperCase()]: 'SECRET_VALUE' })).toEqual({
      [key.toUpperCase()]: REDACTED,
    });
  });

  it('preserves useful business metadata and public names, masking actual User data', () => {
    expect(
      sanitizeForLog({ restaurantId: '123', status: 'OPEN', name: 'Pizza' }),
    ).toEqual({
      restaurantId: '123',
      status: 'OPEN',
      name: 'Pizza',
    });
    expect(
      sanitizeForLog({
        user: { email: 'tester@example.com', name: 'Private Name' },
      }),
    ).toEqual({
      user: { email: 'te***@example.com', name: REDACTED },
    });
    expect(
      sanitizeForLog({
        phoneNumber: '01012345678',
        address: 'Home',
        birth: '2000-01-01',
      }),
    ).toEqual({
      phoneNumber: REDACTED,
      address: REDACTED,
      birth: REDACTED,
    });
  });

  it('does not mutate input; handles null, undefined, cycles, getters and bigint', () => {
    const input: Record<string, unknown> = {
      password: 'UNCHANGED',
      child: Object.freeze({ accessToken: 'ORIGINAL' }),
      n: 12n,
    };
    input.self = input;
    Object.defineProperty(input, 'throwing', {
      enumerable: true,
      get() {
        throw new Error('GETTER_SECRET');
      },
    });
    const output = sanitizeForLog(Object.freeze(input));
    expect(JSON.stringify(output)).not.toMatch(
      /UNCHANGED|ORIGINAL|GETTER_SECRET/,
    );
    expect(output).toMatchObject({
      self: '[CIRCULAR]',
      throwing: '[GETTER]',
      n: '12',
    });
    expect(input.password).toBe('UNCHANGED');
    expect(input.child).toEqual({ accessToken: 'ORIGINAL' });
    expect(sanitizeForLog(null)).toBeNull();
    expect(sanitizeForLog(undefined)).toBeUndefined();
  });

  it('redacts serialized objects, Bearer strings, JWTs and credential URLs', () => {
    for (const value of [
      '{"password":"SERIALIZED_SECRET","status":"OPEN"}',
      'Bearer VERY_SECRET_JWT',
      'Cookie: refreshToken=COOKIE_SECRET',
      [
        Buffer.from(JSON.stringify({ alg: 'HS256' })).toString('base64url'),
        Buffer.from(JSON.stringify({ sub: 'synthetic-user' })).toString('base64url'),
        'SIGNATURE_SECRET',
      ].join('.'),
      'https://user:URL_PASSWORD@example.com/verify?token=URL_TOKEN&status=OPEN#FRAGMENT_SECRET',
    ]) {
      expect(JSON.stringify(sanitizeForLog(value))).not.toMatch(
        /SERIALIZED_SECRET|VERY_SECRET_JWT|COOKIE_SECRET|SIGNATURE_SECRET|URL_PASSWORD|URL_TOKEN|FRAGMENT_SECRET/,
      );
    }
  });

  it('masks encoded/duplicate query secrets and preserves safe query values', () => {
    const url = sanitizeLogUrl(
      '/orders?%74oken=QUERY_ONE&token=QUERY_TWO&api_key=API_SECRET&restaurantId=123',
    );
    expect(url).not.toMatch(/QUERY_ONE|QUERY_TWO|API_SECRET/);
    expect(url).toContain('restaurantId=123');
  });

  it.each(['sign-in', 'sign-up', 'sign-out', 'refresh', 'verify-email'])(
    'suppresses auth body/query for %s',
    (route) => {
      const request = {
        method: 'POST',
        originalUrl: `/auth/${route}?token=SECRET`,
        route: { path: `/auth/${route}` },
        body: { password: 'SECRET' },
        query: { token: 'SECRET' },
      } as unknown as Request;
      expect(requestForLog(request)).toEqual({
        method: 'POST',
        url: `/auth/${route}`,
      });
    },
  );

  it('discards all body/query values and raw paths even outside auth', () => {
    const req = { method: 'PATCH', url: '/users/PRIVATE_VALUE', body: { name: 'Private Name' }, query: { q: 'PRIVATE_VALUE' } } as unknown as Request;
    expect(requestForLog(req)).toEqual({ method: 'PATCH', url: 'unmatched' });
    expect(req.body).toEqual({ name: 'Private Name' });
  });
});
