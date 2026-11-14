import { Injectable, type ExecutionContext } from '@nestjs/common';
import {
  ThrottlerGuard,
  ThrottlerException,
  type ThrottlerRequest,
  type ThrottlerLimitDetail,
} from '@nestjs/throttler';
import { createHash } from 'node:crypto';
import type { Request, Response } from 'express';
import { isUUID } from 'class-validator';
import {
  RATE_PROXY_SETTINGS,
  RateLimitProxySettings,
  rateLimitClientIp,
} from './client-ip';

abstract class HttpRateLimitGuard extends ThrottlerGuard {
  protected shouldSkip(context: ExecutionContext): Promise<boolean> {
    return Promise.resolve(context.getType() !== 'http');
  }

  protected clientIp(request: Request): string {
    const settings: unknown = request.app.get(RATE_PROXY_SETTINGS);
    return rateLimitClientIp(
      request,
      settings instanceof RateLimitProxySettings
        ? settings
        : new RateLimitProxySettings(),
    );
  }

  protected throwThrottlingException(
    context: ExecutionContext,
    detail: ThrottlerLimitDetail,
  ): Promise<void> {
    context
      .switchToHttp()
      .getResponse<Response>()
      .setHeader('Retry-After', detail.timeToBlockExpire);
    return Promise.reject(
      new ThrottlerException('Too many requests. Please try again later.'),
    );
  }
}

@Injectable()
export class IpRateLimitGuard extends HttpRateLimitGuard {
  protected getTracker(request: Request): Promise<string> {
    return Promise.resolve(`ip:${this.clientIp(request)}`);
  }
  protected generateKey(
    _context: ExecutionContext,
    tracker: string,
    name: string,
  ): string {
    return createHash('sha256').update(`${name}:${tracker}`).digest('hex');
  }
  protected handleRequest(props: ThrottlerRequest): Promise<boolean> {
    return props.throttler.name === 'baseline'
      ? super.handleRequest(props)
      : Promise.resolve(true);
  }
}

@Injectable()
export class ApiRateLimitGuard extends HttpRateLimitGuard {
  protected getTracker(request: Request): Promise<string> {
    // Runs after AccessTokenGuard. Public auth routes never derive identity
    // from unverified JWT, email, password or refresh cookie.
    const user: unknown = request.user;
    if (
      typeof user === 'object' &&
      user !== null &&
      'id' in user &&
      typeof user.id === 'string' &&
      isUUID(user.id)
    ) {
      return Promise.resolve(`user:${user.id}`);
    }
    return Promise.resolve(`ip:${this.clientIp(request)}`);
  }
  protected handleRequest(props: ThrottlerRequest): Promise<boolean> {
    return props.throttler.name === 'default'
      ? super.handleRequest(props)
      : Promise.resolve(true);
  }
}
