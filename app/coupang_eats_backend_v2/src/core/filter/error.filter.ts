import {
  ExceptionFilter,
  Catch,
  ArgumentsHost,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { Request, Response } from 'express';
import { LoggerService } from '../logger/logger.service';
import { MoinConfigService } from '../config/config.service';
import { requestForLog } from '../logger/log-sanitizer';
import { errorFields } from '../logger/safe-event';

interface ErrorResponse {
  statusCode: number;
  message: string | string[];
  path: string;
  error: string;
}

/**
 * 애플리케이션 전역에서 발생하는 모든 예외를 포착하여
 * 1. 보안을 위한 민감 정보 마스킹
 * 2. 구조화된 에러 로그 기록(Winston + CloudWatch)
 * 3. 클라이언트에게 통일된 에러 응답 반환의 역할을 수행
 */
@Catch()
export class ErrorFilter implements ExceptionFilter {
  constructor(
    private readonly loggerService: LoggerService,
    private readonly configService: MoinConfigService,
  ) {}

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const request = ctx.getRequest<Request>();
    const response = ctx.getResponse<Response>();
    // 미들웨어(CLS)에서 생성한 고유 Request Id 가져옴, 추적용
    const requestId = request.headers['x-request-id'] as string;

    // 기본값: 500 내부 서버 오류
    const statusCode =
      exception instanceof HttpException
        ? exception.getStatus()
        : HttpStatus.INTERNAL_SERVER_ERROR;
    let message: string | string[] = 'Internal Server Error';

    // Nest.js 표준 예외인 경우, 해당 상태 코드와 메시지를 따름
    if (exception instanceof HttpException && statusCode < 500) {
      const httpPayload = exception.getResponse();
      if (typeof httpPayload === 'string') {
        message = httpPayload;
      } else if ('message' in httpPayload) {
        if (typeof httpPayload.message === 'string') {
          message = httpPayload.message;
        } else if (Array.isArray(httpPayload.message)) {
          message = httpPayload.message.filter(
            (item: unknown): item is string => typeof item === 'string',
          );
        }
      }
    }

    // 모든 환경에서 stack/raw exception payload를 응답에 포함하지 않는다.
    const errorResponse: ErrorResponse = {
      statusCode,
      message,
      path: request.path ?? request.url.split('?')[0],
      error:
        statusCode >= 500
          ? 'InternalServerError'
          : exception instanceof HttpException
            ? exception.name
            : 'Error',
    };

    const req = requestForLog(request);
    this.loggerService.event('http.exception', statusCode >= 500 ? 'ERROR' : 'WARN', {
      ...errorFields(exception), request_id: requestId, http_method: request.method,
      http_route: req.url, status_code: statusCode,
    });

    // 클라이언트에게 보낼 최종 응답 객체(통일된 포맷)
    const returnObj = {
      success: false,
      ...errorResponse,
    };

    return response.status(statusCode).json(returnObj);
  }
}
