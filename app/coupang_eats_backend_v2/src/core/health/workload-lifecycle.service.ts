import {
  Injectable,
  type BeforeApplicationShutdown,
  type OnApplicationBootstrap,
  type OnApplicationShutdown,
  type OnModuleDestroy,
} from '@nestjs/common';
import type { RequestHandler } from 'express';
import type { Server } from 'node:http';
import { SafeConsoleLogger } from '../logger/safe-console.logger';

export const HTTP_DRAIN_TIMEOUT_MS = 30_000;

@Injectable()
export class WorkloadLifecycleService
  implements
    OnApplicationBootstrap,
    OnModuleDestroy,
    BeforeApplicationShutdown,
    OnApplicationShutdown
{
  private readonly logger = new SafeConsoleLogger(
    WorkloadLifecycleService.name,
  );
  private server?: Server;
  private activeRequests = 0;
  private drained?: () => void;
  private deadline?: ReturnType<typeof setTimeout>;
  private started = false;
  private draining = false;

  get hasStarted(): boolean {
    return this.started;
  }

  get isDraining(): boolean {
    return this.draining;
  }

  bindServer(server: Server): void {
    this.server = server;
    server.once('close', () => this.clearDeadline());
  }

  onApplicationBootstrap(): void {
    this.started = true;
  }

  beginDrain(): void {
    if (this.draining) return;
    this.draining = true;
    this.logger.log({ event: 'shutdown_start' });
  }

  // Count all accepted responses before body parsing/guards, including health.
  // The local drain handler marks state without waiting for this counter.
  readonly trackRequests: RequestHandler = (request, response, next) => {
    const health = /^\/health(?:\/(?:live|ready|startup|drain))?\/?$/i.test(
      request.path,
    );
    const metrics = /^\/metrics\/?$/i.test(request.path);
    // Keep final scrapes available. They remain counted and deadline-bounded.
    if (this.draining && !health && !metrics) {
      response.setHeader('Connection', 'close');
      response.status(503).json({ status: 'unavailable' });
      return;
    }
    this.activeRequests += 1;
    let completed = false;
    const complete = () => {
      if (completed) return;
      completed = true;
      response.off('finish', complete);
      response.off('close', complete);
      this.activeRequests -= 1;
      if (this.activeRequests === 0) this.drained?.();
    };
    response.once('finish', complete);
    response.once('close', complete);
    next();
  };

  onModuleDestroy(): void {
    // Also handles direct SIGTERM without a successful Kubernetes preStop.
    this.beginDrain();
  }

  async beforeApplicationShutdown(): Promise<void> {
    this.beginDrain();
    // Keep the deadline armed through Nest's native server.close, including
    // health/idle connections arriving between hooks. Clear on actual close.
    if (!this.deadline && (this.server || this.activeRequests > 0)) {
      this.deadline = setTimeout(() => {
        this.logger.warn({ event: 'http_drain_timeout' });
        this.server?.closeAllConnections();
        this.drained?.();
      }, HTTP_DRAIN_TIMEOUT_MS);
      this.deadline.unref();
    }
    if (this.activeRequests > 0) {
      try {
        await new Promise<void>((resolve) => {
          this.drained = resolve;
        });
      } finally {
        this.drained = undefined;
      }
    }
    this.logger.log({ event: 'http_drain_complete' });
    // Nest closes its HTTP/Socket.IO servers next; TypeORM's existing
    // onApplicationShutdown destroys the pool afterwards. No duplicate destroy.
  }

  onApplicationShutdown(): void {
    this.clearDeadline();
  }

  private clearDeadline(): void {
    if (this.deadline) clearTimeout(this.deadline);
    this.deadline = undefined;
  }
}
