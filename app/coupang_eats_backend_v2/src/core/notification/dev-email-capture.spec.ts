import { createHash } from 'node:crypto';
import { connect } from 'node:net';
import { DevEmailCaptureService } from './dev-email-capture.service';
import { EmailService } from './email.service';
import { ConfigService } from '@nestjs/config';
import { Configurations } from '../config';
import { LoggerService } from '../logger/logger.service';
import { AwsSesService } from '../aws/aws-ses.service';

const EMAIL = 'capture@example.invalid';
const HASH = createHash('sha256').update(EMAIL).digest('hex');
const LINK =
  'https://dev.example.com/verify-email?token=00000000-0000-4000-8000-000000000001';
export function takeCaptured(
  hash = HASH,
): Promise<{ found: boolean; verificationUrl?: string }> {
  return new Promise((resolve, reject) => {
    const socket = connect({ host: '127.0.0.1', port: 3217 });
    let body = '';
    socket.setTimeout(2500, () =>
      socket.destroy(new Error('PRIVATE_CAPTURE_TIMEOUT')),
    );
    socket.on('connect', () => socket.write(`TAKE ${hash}\n`));
    socket.on('data', (x) => {
      body += x.toString();
    });
    socket.on('end', () => {
      try {
        resolve(JSON.parse(body));
      } catch {
        reject(new Error('PRIVATE_CAPTURE_REPLY'));
      }
    });
    socket.on('error', reject);
  });
}

describe('Dev private email transport', () => {
  const original = { ...process.env };
  let capture: DevEmailCaptureService | undefined;
  beforeEach(() => {
    Object.assign(process.env, {
      NODE_ENV: 'dev',
      SKIP_EMAIL_NOTIFICATION: 'true',
      AUTO_VERIFY_USERS: 'false',
      BASE_URL: 'https://dev.example.com',
      DEV_EMAIL_CAPTURE_ENABLED: 'true',
      DEV_EMAIL_CAPTURE_ORIGIN: 'https://dev.example.com',
      DEV_EMAIL_CAPTURE_ADDRESS_SHA256: HASH,
    });
  });
  afterEach(async () => {
    await capture?.onApplicationShutdown();
    capture = undefined;
    process.env = { ...original };
    jest.restoreAllMocks();
  });
  async function start() {
    capture = new DevEmailCaptureService();
    await capture.onModuleInit();
    return capture;
  }

  it('is disabled by default, including normal production behavior', async () => {
    delete process.env.DEV_EMAIL_CAPTURE_ENABLED;
    process.env.NODE_ENV = 'prod';
    const c = await start();
    expect(c.capture(EMAIL, LINK)).toBe(false);
    expect((c as any).server).toBeUndefined();
  });
  it.each(['prod', 'production', 'local', 'test'])(
    'rejects enabling outside dev: %s',
    (env) => {
      process.env.NODE_ENV = env;
      expect(() => new DevEmailCaptureService()).toThrow(
        'CONFIGURATION_REJECTED',
      );
    },
  );
  it.each(['false', ''])(
    'requires external email to remain disabled: %s',
    (skip) => {
      process.env.SKIP_EMAIL_NOTIFICATION = skip;
      expect(() => new DevEmailCaptureService()).toThrow(
        'CONFIGURATION_REJECTED',
      );
    },
  );
  it('rejects any auto-verification bypass', () => {
    process.env.AUTO_VERIFY_USERS = 'true';
    expect(() => new DevEmailCaptureService()).toThrow(
      'CONFIGURATION_REJECTED',
    );
  });
  it('rejects a missing/ambiguous address allowlist and wrong public origin', () => {
    process.env.DEV_EMAIL_CAPTURE_ADDRESS_SHA256 = HASH + ',' + HASH;
    expect(() => new DevEmailCaptureService()).toThrow(
      'CONFIGURATION_REJECTED',
    );
    process.env.DEV_EMAIL_CAPTURE_ADDRESS_SHA256 = HASH;
    process.env.BASE_URL = 'https://example.invalid';
    expect(() => new DevEmailCaptureService()).toThrow(
      'CONFIGURATION_REJECTED',
    );
    process.env.BASE_URL = 'https://dev.example.com';
    for (const origin of ['', 'http://dev.example.com', 'https://dev.example.com/x']) {
      process.env.DEV_EMAIL_CAPTURE_ORIGIN = origin;
      expect(() => new DevEmailCaptureService()).toThrow(
        'CONFIGURATION_REJECTED',
      );
    }
  });
  it('binds only pod loopback and captures one exact recipient, once', async () => {
    const c = await start();
    expect((c as any).server.address().address).toBe('127.0.0.1');
    expect(c.capture('other@example.invalid', LINK)).toBe(false);
    expect((await takeCaptured()).found).toBe(false);
    expect(c.capture(EMAIL, LINK)).toBe(true);
    expect((await takeCaptured('0'.repeat(64))).found).toBe(false);
    const item = await takeCaptured();
    expect(item.found).toBe(true);
    expect(item.verificationUrl === LINK).toBe(true);
    expect((await takeCaptured()).found).toBe(false);
  });
  it('drops expired links and clears on shutdown', async () => {
    const c = await start();
    c.capture(EMAIL, LINK);
    const now = Date.now();
    jest.spyOn(Date, 'now').mockReturnValue(now + 300_001);
    expect((await takeCaptured()).found).toBe(false);
    jest.restoreAllMocks();
    c.capture(EMAIL, LINK);
    await c.onApplicationShutdown();
    expect((c as any).captured).toBeUndefined();
  });
  it.each([
    LINK.replace('dev.example.com', 'other.invalid'),
    LINK + '&other=1',
    LINK + '#fragment',
    LINK.replace('/verify-email', '/auth/sign-in'),
  ])(
    'rejects an unexpected verification link without echoing it',
    async (url) => {
      const c = await start();
      expect(() => c.capture(EMAIL, url)).toThrow('LINK_REJECTED');
    },
  );
  it('never sends captured mail or logs the link; uncaptured dev mail remains skipped', async () => {
    const c = await start();
    const info = jest.fn();
    const sendEmail = jest.fn();
    const service = new EmailService(
      { info } as unknown as LoggerService,
      { sendEmail } as unknown as AwsSesService,
      {
        get: (key: string) =>
          key === 'APP.BASE_URL'
            ? 'https://dev.example.com'
            : 'sender@example.invalid',
      } as unknown as ConfigService<Configurations>,
      c,
    );
    await service.sendWelcomeNotification(
      EMAIL,
      'Test',
      new URL(LINK).searchParams.get('token')!,
    );
    expect(sendEmail).not.toHaveBeenCalled();
    expect(info).not.toHaveBeenCalled();
    await service.sendWelcomeNotification(
      'other@example.invalid',
      'Test',
      'unused',
    );
    expect(sendEmail).not.toHaveBeenCalled();
    expect(JSON.stringify(info.mock.calls).includes('token=')).toBe(false);
  });
});
