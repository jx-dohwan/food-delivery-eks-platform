import {
  Injectable,
  OnModuleInit,
  OnApplicationShutdown,
} from '@nestjs/common';
import { createHash } from 'node:crypto';
import { createServer, Server } from 'node:net';

/** Private test transport, not a Nest HTTP route, Service or public inbox. */
@Injectable()
export class DevEmailCaptureService
  implements OnModuleInit, OnApplicationShutdown
{
  private readonly enabled = process.env.DEV_EMAIL_CAPTURE_ENABLED === 'true';
  private readonly recipientHash =
    process.env.DEV_EMAIL_CAPTURE_ADDRESS_SHA256 || '';
  // The one dev origin allowed to use capture; deployment injects it, so no domain lives in code.
  private readonly origin = process.env.DEV_EMAIL_CAPTURE_ORIGIN || '';
  private server?: Server;
  private captured?: { verificationUrl: string; expiresAt: number };
  private expiry?: NodeJS.Timeout;

  constructor() {
    if (!this.enabled) return;
    if (
      process.env.NODE_ENV !== 'dev' ||
      process.env.AUTO_VERIFY_USERS === 'true' ||
      process.env.SKIP_EMAIL_NOTIFICATION !== 'true' ||
      !/^https:\/\/[a-z0-9.-]+$/.test(this.origin) ||
      process.env.BASE_URL !== this.origin ||
      !/^[a-f0-9]{64}$/.test(this.recipientHash)
    ) {
      throw new Error('DEV_EMAIL_CAPTURE_CONFIGURATION_REJECTED');
    }
  }

  async onModuleInit(): Promise<void> {
    if (!this.enabled) return;
    const server = createServer((socket) => {
      socket.setTimeout(1500, () => socket.destroy());
      socket.on('error', () => socket.destroy());
      let input = '';
      socket.on('data', (chunk: Buffer) => {
        input += chunk.toString('utf8');
        if (Buffer.byteLength(input) > 128) {
          socket.destroy();
          return;
        }
        if (!input.includes('\n')) return;
        const authorized = input === `TAKE ${this.recipientHash}\n`;
        const item = authorized ? this.captured : undefined;
        if (authorized) this.clear();
        const available =
          item && item.expiresAt > Date.now() ? item : undefined;
        // Raw credentials never enter HTTP middleware, application logs or files.
        socket.end(
          JSON.stringify(
            available
              ? { found: true, verificationUrl: available.verificationUrl }
              : { found: false },
          ) + '\n',
        );
      });
    });
    server.maxConnections = 4;
    await new Promise<void>((resolve, reject) => {
      server.once('error', reject);
      server.listen(3217, '127.0.0.1', () => {
        server.removeListener('error', reject);
        resolve();
      });
    });
    server.on('error', () => this.clear());
    this.server = server;
  }

  capture(email: string, verificationUrl: string): boolean {
    if (!this.enabled) return false;
    if (createHash('sha256').update(email).digest('hex') !== this.recipientHash)
      return false;
    if (!this.server?.listening) throw new Error('DEV_EMAIL_CAPTURE_NOT_READY');
    let url: URL;
    try {
      url = new URL(verificationUrl);
    } catch {
      throw new Error('DEV_EMAIL_CAPTURE_LINK_REJECTED');
    }
    if (
      url.origin !== this.origin ||
      url.pathname !== '/verify-email' ||
      url.username ||
      url.password ||
      url.hash ||
      [...url.searchParams.keys()].join(',') !== 'token' ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(
        url.searchParams.get('token') || '',
      )
    )
      throw new Error('DEV_EMAIL_CAPTURE_LINK_REJECTED');
    this.clear();
    // Original Redis token TTL/verification remain authoritative, unchanged.
    this.captured = { verificationUrl, expiresAt: Date.now() + 300_000 };
    this.expiry = setTimeout(() => this.clear(), 300_000);
    this.expiry.unref();
    return true;
  }

  private clear(): void {
    this.captured = undefined;
    if (this.expiry) clearTimeout(this.expiry);
    this.expiry = undefined;
  }

  async onApplicationShutdown(): Promise<void> {
    this.clear();
    const server = this.server;
    this.server = undefined;
    if (server?.listening)
      await new Promise<void>((resolve) => server.close(() => resolve()));
  }
}
