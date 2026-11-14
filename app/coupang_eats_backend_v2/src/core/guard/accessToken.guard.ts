import {
  ExecutionContext,
  HttpException,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';
import { Reflector } from '@nestjs/core';
import { Observable } from 'rxjs';
import { LoggerService } from '../logger/logger.service';
import { IS_PUBLIC_KEY } from '../decorator/public.decorator';
import { isRFC3339 } from 'class-validator';
import { RequestContextService } from '../cls/cls.service';

// Request-local only. Shared by global and controller guard instances; never
// persisted across HTTP requests and cannot be supplied by a client header.
const verifiedRequests = new WeakMap<object, unknown>();

@Injectable()
export class AccessTokenGuard extends AuthGuard('jwt-access') {
  constructor(
    private readonly reflector: Reflector,
    private readonly loggerService: LoggerService,
    private readonly requestContextService: RequestContextService,
  ) {
    super();
  }

  // 가드 실행 진입점, 요청이 들어오면 가장 먼저 실행되는 메서드이다.
  async canActivate(
    context: ExecutionContext,
  ): Promise<boolean> {
    // @Public() 데코레이터가 붙어있는지
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(), // 메서드 레벨 확인
      context.getClass(), // 클래스 레벨 확인
    ]);
    if (isPublic) { // public이면 인증 검사 없이 통과(true 반환)
      return true;
    }

    // public이 아니면 부모 로직 실행 -> Strategy의 validate() 호출됨
    const request = context.switchToHttp().getRequest();
    if (request.user && verifiedRequests.get(request) === request.user) return true;
    const accepted = await super.canActivate(context);
    if (accepted !== true) return false;
    verifiedRequests.set(request, request.user);
    return true;
  }

  /**
   * 요청 처리 핸들러로 Strategy 검증이 끝난 후 호출된다. 예외 처리를 커스텀
   * @param err  - Passport 내부 에러
   * @param user - Strategy의 validate()가 반환한 유저 객체
   * @returns
   */
  handleRequest(err: any, user: any) {
    // 에러가 있거나 유저를 찾지 못했으면 예외 발생
    // Strategy errors keep their server/error classification. JWT rejection
    // without a user is handled below; ErrorFilter sanitizes unexpected errors.
    if (err) throw err;
    if (!user) throw new UnauthorizedException('invalid token');

    return user;
  }
}
