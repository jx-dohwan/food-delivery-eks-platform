import { Injectable, NestMiddleware } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { Request, Response, NextFunction } from 'express';
import { LoggerService } from '../logger/logger.service';
import { RequestContextService } from '../cls/cls.service';
import { activeTrace } from '../logger/safe-event';
@Injectable()
export class RequestLoggerMiddleware implements NestMiddleware {
  constructor(private readonly logger: LoggerService, private readonly context: RequestContextService) {}
  use(req: Request, res: Response, next: NextFunction): void {
    const start = performance.now();
    const requestId = this.context.getRequestId() || randomUUID();
    req.headers['x-request-id'] = requestId;
    res.setHeader('X-Request-ID', requestId);
    const span = activeTrace();
    res.on('finish', () => {
      const route: string = typeof req.route?.path === 'string' ? req.route.path : 'unmatched';
      if (['/metrics', '/health', '/health/live', '/health/ready'].includes(route)) return;
      const auth = route.startsWith('/auth');
      const status = res.statusCode;
      if (status < 400 && !auth && Math.random() >= 0.1) return;
      const event = status === 403 ? 'access.denied' : auth ? (status < 400 ? 'auth.succeeded' : 'auth.failed') : status >= 400 ? 'http.failed' : 'http.completed';
      this.logger.event(event, status >= 500 ? 'ERROR' : status >= 400 ? 'WARN' : 'INFO', {
        request_id: requestId, ...span, http_method: req.method, http_route: route,
        status_code: status, duration_ms: performance.now() - start,
      });
    });
    next();
  }
}
