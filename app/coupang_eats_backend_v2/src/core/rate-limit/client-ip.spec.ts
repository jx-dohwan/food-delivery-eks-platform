import { RateLimitProxySettings, rateLimitClientIp } from './client-ip';

describe('trusted ALB → Nginx client address', () => {
  const settings = new RateLimitProxySettings(
    ['10.0.0.0/24', '10.0.1.0/24', '10.0.2.0/24'],
    ['10.0.10.0/24', '10.0.11.0/24', '10.0.12.0/24'],
  );
  const request = (remoteAddress: string, forwarded?: string) => ({
    socket: { remoteAddress },
    headers: { 'x-forwarded-for': forwarded },
  });
  it('ignores spoofed XFF from an untrusted direct caller', () => {
    expect(rateLimitClientIp(request('203.0.113.7', '1.2.3.4'), settings)).toBe(
      '203.0.113.7',
    );
  });
  it('selects the address appended by ALB behind Nginx, not the forged prefix', () => {
    expect(
      rateLimitClientIp(
        request('10.0.11.55', '1.2.3.4, 203.0.113.7, 10.0.1.44'),
        settings,
      ),
    ).toBe('203.0.113.7');
  });
  it('does not trust an arbitrary second reverse proxy', () => {
    expect(
      rateLimitClientIp(
        request('10.0.11.55', '203.0.113.7, 192.168.0.44'),
        settings,
      ),
    ).toBe('10.0.11.55');
  });
  it('supports direct ALB targets and ignores earlier header entries', () => {
    expect(
      rateLimitClientIp(request('10.0.1.44', '1.2.3.4, 203.0.113.7'), settings),
    ).toBe('203.0.113.7');
  });
  it('never uses a left-side spoofed value when the trusted suffix is missing', () => {
    expect(rateLimitClientIp(request('10.0.11.55', '1.2.3.4'), settings)).toBe(
      '10.0.11.55',
    );
    expect(
      rateLimitClientIp(request('10.0.1.44', '1.2.3.4, invalid'), settings),
    ).toBe('10.0.1.44');
  });
  it('normalizes IPv4 mapped addresses and strips client ports', () => {
    expect(
      rateLimitClientIp(
        request('::ffff:10.0.11.55', '203.0.113.7:5000, 10.0.1.44'),
        settings,
      ),
    ).toBe('203.0.113.7');
    expect(
      rateLimitClientIp(request('10.0.1.44', '::ffff:203.0.113.7'), settings),
    ).toBe('203.0.113.7');
  });
  it('canonicalizes IPv6 and strips bracketed ALB client ports', () => {
    expect(
      rateLimitClientIp(
        request('10.0.1.44', '[2001:0DB8:0:0:0:0:0:1]:5000'),
        settings,
      ),
    ).toBe('2001:db8::1');
  });
  it('trusts only two expected proxy positions', () => {
    expect(settings.trustHop('10.0.11.55', 0)).toBe(true);
    expect(settings.trustHop('10.0.1.44', 1)).toBe(true);
    expect(settings.trustHop('10.0.11.55', 1)).toBe(false);
    expect(settings.trustHop('10.0.1.44', 2)).toBe(false);
    expect(settings.trustHop('127.0.0.1', 0)).toBe(false);
  });
  it.each(['[2001:db8::1', '[2001:db8::1]garbage', 'fe80::1%eth0'])(
    'falls back safely for malformed/scoped forwarded addresses: %s',
    (address) => {
      expect(rateLimitClientIp(request('10.0.1.44', address), settings)).toBe(
        '10.0.1.44',
      );
    },
  );
  it('trusts no deployment networks when configuration is absent', () => {
    const empty = new RateLimitProxySettings([], []);
    expect(empty.trustHop('10.0.11.55', 0)).toBe(false);
    expect(empty.trustHop('10.0.1.44', 1)).toBe(false);
  });
  it('rejects invalid/all-address CIDR configurations', () => {
    expect(() => new RateLimitProxySettings(['0.0.0.0/0'])).toThrow();
    expect(() => new RateLimitProxySettings(['invalid'])).toThrow();
  });
});
