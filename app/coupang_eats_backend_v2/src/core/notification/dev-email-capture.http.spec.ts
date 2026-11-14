import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createHash } from 'node:crypto';
import { connect } from 'node:net';
import request from 'supertest';
import { AuthController } from '../../modules/auth/auth.controller';
import { AuthService } from '../../modules/auth/auth.service';
import { AuthTxService } from '../../modules/auth/auth.tx.service';
import { UserRepository } from '../../modules/user/repository/user.repository';
import { TokenService } from '../jwt/jwt.service';
import { CacheService } from '../cache/cache.service';
import { IHashService } from '../hash/hash.interface';
import { RequestContextService } from '../cls/cls.service';
import { LoggerService } from '../logger/logger.service';
import { AwsSesService } from '../aws/aws-ses.service';
import { Configurations } from '../config';
import { DevEmailCaptureService } from './dev-email-capture.service';
import { EmailService } from './email.service';

const email = 'capture-http@example.invalid';
const hash = createHash('sha256').update(email).digest('hex');
async function take(): Promise<{ found: boolean; verificationUrl?: string }> {
  return new Promise((resolve, reject) => {
    const socket = connect(3217, '127.0.0.1');
    let body = '';
    socket.setTimeout(2000, () =>
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

describe('Original Auth HTTP + private transport (local fixture stores, no AWS)', () => {
  const original = { ...process.env };
  let app: INestApplication;
  let user: any;
  let savedTtl: number | undefined;
  let store: Map<string, { value: string; expires: number }>;
  const sendEmail = jest.fn();
  const issued = jest.fn();
  beforeEach(async () => {
    Object.assign(process.env, {
      NODE_ENV: 'dev',
      BASE_URL: 'https://dev.example.com',
      SKIP_EMAIL_NOTIFICATION: 'true',
      AUTO_VERIFY_USERS: 'false',
      DEV_EMAIL_CAPTURE_ENABLED: 'true',
      DEV_EMAIL_CAPTURE_ORIGIN: 'https://dev.example.com',
      DEV_EMAIL_CAPTURE_ADDRESS_SHA256: hash,
    });
    user = undefined;
    store = new Map();
    savedTtl = undefined;
    sendEmail.mockReset();
    issued
      .mockReset()
      .mockResolvedValue({
        accessToken: 'local-fixture-access',
        refreshToken: 'local-fixture-refresh',
      });
    const capture = new DevEmailCaptureService();
    const mail = new EmailService(
      { info: jest.fn() } as unknown as LoggerService,
      { sendEmail } as unknown as AwsSesService,
      {
        get: (k: string) =>
          k === 'APP.BASE_URL'
            ? 'https://dev.example.com'
            : 'configured@example.invalid',
      } as unknown as ConfigService<Configurations>,
      capture,
    );
    const cache = {
      set: async (key: string, value: string, ttl: number) => {
        savedTtl = ttl;
        store.set(key, { value, expires: Date.now() + ttl * 1000 });
      },
      get: async (key: string) => {
        const x = store.get(key);
        return x && x.expires > Date.now() ? x.value : null;
      },
      del: async (key: string) => {
        store.delete(key);
      },
    };
    const auth = new AuthService(
      {
        createUserOrThrow: async () => {
          user = {
            id: '00000000-0000-4000-8000-000000000001',
            email,
            password: 'fixture-hash',
            verified: false,
          };
        },
      } as unknown as AuthTxService,
      {
        findOneByFilters: async () => user || null,
        findOneOrThrow: async () => user,
        save: async () => user,
      } as unknown as UserRepository,
      { generateTokenPair: issued } as unknown as TokenService,
      { error: jest.fn() } as unknown as LoggerService,
      cache as unknown as CacheService,
      {
        hash: async () => 'fixture-hash',
        compare: async () => true,
      } as unknown as IHashService,
      mail,
    );
    const module = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [
        { provide: AuthService, useValue: auth },
        { provide: DevEmailCaptureService, useValue: capture },
        { provide: LoggerService, useValue: { error: jest.fn() } },
        { provide: RequestContextService, useValue: {} },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    await app.init();
  });
  afterEach(async () => {
    await app?.close();
    process.env = { ...original };
    jest.restoreAllMocks();
  });

  it('signup 201 -> login 401 -> original link 200 -> login 200; same UUID token and TTL300', async () => {
    await request(app.getHttpServer())
      .post('/auth/sign-up')
      .send({
        email,
        password: 'Fixture1!',
        name: 'Local fixture',
        role: 'Client',
      })
      .expect(201);
    expect(user.verified).toBe(false);
    expect(savedTtl).toBe(300);
    expect(sendEmail).not.toHaveBeenCalled();
    await request(app.getHttpServer())
      .post('/auth/sign-in')
      .send({ email, password: 'Fixture1!' })
      .expect(401);
    expect(issued).not.toHaveBeenCalled();
    const item = await take();
    expect(item.found).toBe(true);
    const url = new URL(item.verificationUrl!);
    const token = url.searchParams.get('token')!;
    expect(store.has(`email-verify:${token}`)).toBe(true);
    await request(app.getHttpServer())
      .get('/auth/verify-email')
      .query({ token })
      .expect(200);
    expect(user.verified).toBe(true);
    expect(store.has(`email-verify:${token}`)).toBe(false);
    await request(app.getHttpServer())
      .get('/auth/verify-email')
      .query({ token })
      .expect(400);
    await request(app.getHttpServer())
      .post('/auth/sign-in')
      .send({ email, password: 'Fixture1!' })
      .expect(200);
    expect(issued).toHaveBeenCalledTimes(1);
    expect(sendEmail).not.toHaveBeenCalled();
  });
  it('the original verification rejects expired tokens without authenticating the user', async () => {
    await request(app.getHttpServer())
      .post('/auth/sign-up')
      .send({
        email,
        password: 'Fixture1!',
        name: 'Local fixture',
        role: 'Client',
      })
      .expect(201);
    const item = await take();
    const token = new URL(item.verificationUrl!).searchParams.get('token')!;
    const now = Date.now();
    jest.spyOn(Date, 'now').mockReturnValue(now + 300_001);
    await request(app.getHttpServer())
      .get('/auth/verify-email')
      .query({ token })
      .expect(400);
    expect(user.verified).toBe(false);
    expect(issued).not.toHaveBeenCalled();
  });
});
