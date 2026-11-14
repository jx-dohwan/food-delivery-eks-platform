import {
  CallHandler,
  ExecutionContext,
  Injectable,
  NestInterceptor,
} from '@nestjs/common';
import { map } from 'rxjs';
import type { Request } from 'express';
import { sanitizeApiResponse } from './response-sanitizer';

@Injectable()
export class ApiResponseInterceptor implements NestInterceptor {
  // intercept 메서드는 Nest.js의 모든 요청/응답 사이클에 개입
  intercept(context: ExecutionContext, next: CallHandler) {
    const request = context.switchToHttp().getRequest<Request>();
    const route: unknown = request.route;
    const routePath =
      typeof route === 'object' &&
      route !== null &&
      'path' in route &&
      typeof route.path === 'string'
        ? route.path
        : request.path;
    const allowAccessToken =
      request.method === 'POST' &&
      ['/auth/sign-in', '/auth/refresh'].includes(routePath);
    // next.handle()은 다음 핸들러(또는 컨트롤러)로 요청을 전달하고,
    // 그 결과를 Observable 스트림으로 받환받다.
    return next.handle().pipe(
      // 컨트롤러에서 반환한 data'를
      // 이 새로운 객체로 감싸서 최종 응답으로 보낸다.
      map((data: unknown) => ({
        success: true, // API 요청이 성공했음을 나타내는 플래그
        data: sanitizeApiResponse(data, allowAccessToken),
      })),
    );
  }
}
