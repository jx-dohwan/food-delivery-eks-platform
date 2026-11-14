import { sanitizeApiResponse } from './response-sanitizer';
import { User } from '../../entities/user/user.entity';

describe('API response credential suppression', () => {
  it('removes password hashes from class entities and plain cached objects without mutation', () => {
    const user = Object.assign(new User(), {
      id: 'A',
      password: '$2b$PRIVATE_HASH',
      email: 'self@example.com',
    });
    const input = { user, cached: { ...user }, data: [{ customer: user }] };
    const output = sanitizeApiResponse(input);
    expect(JSON.stringify(output)).not.toMatch(/password|PRIVATE_HASH/);
    expect(output).toEqual({
      user: { id: 'A', email: 'self@example.com' },
      cached: { id: 'A', email: 'self@example.com' },
      data: [{ customer: { id: 'A', email: 'self@example.com' } }],
    });
    expect(user.password).toBe('$2b$PRIVATE_HASH');
  });
  it.each([
    'PASSWORD',
    'password_hash',
    'refreshToken',
    'accessToken',
    'secret',
    'api_key',
    'awsCredential',
    'DB_PASSWORD',
    'Cookie',
    'Authorization',
    'internalToken',
  ])('omits sensitive key %s from nested arrays', (key) => {
    expect(
      sanitizeApiResponse({ nested: [{ [key]: 'PRIVATE', status: 'OPEN' }] }),
    ).toEqual({ nested: [{ status: 'OPEN' }] });
  });
  it('allows only top-level accessToken for auth issuance, never nested or refresh credentials', () => {
    expect(
      sanitizeApiResponse(
        {
          accessToken: 'issued',
          refreshToken: 'PRIVATE',
          nested: { accessToken: 'PRIVATE' },
        },
        true,
      ),
    ).toEqual({ accessToken: 'issued', nested: {} });
  });
  it('preserves dates and ordinary response fields', () => {
    const date = new Date('2026-01-01T00:00:00Z');
    expect(
      sanitizeApiResponse({ total: 100, restaurantId: 'A', createdAt: date }),
    ).toEqual({ total: 100, restaurantId: 'A', createdAt: date });
  });
  it('handles null, undefined and cycles without recursively failing', () => {
    const value: { self?: unknown; status: string } = { status: 'OPEN' };
    value.self = value;
    expect(JSON.stringify(sanitizeApiResponse(value))).toBe(
      '{"status":"OPEN"}',
    );
    expect(sanitizeApiResponse(null)).toBeNull();
    expect(sanitizeApiResponse(undefined)).toBeUndefined();
  });
});
