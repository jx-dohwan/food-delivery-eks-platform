import { HttpException, Injectable, UnauthorizedException } from '@nestjs/common';
import { AuthGuard } from '@nestjs/passport';
import { LoggerService } from '../logger/logger.service';
import { RequestContextService } from '../cls/cls.service';

@Injectable()
export class RefreshTokenGuard extends AuthGuard('jwt-refresh') {
  constructor(
    private loggerService: LoggerService,
    private readonly requestContextService: RequestContextService,
  ) {
    super();
  }

  /**
   * 부모 클래스의(AuthGuard)의 메서드를 오버라이딩(재정의)한다
   * 전략 실행 결과에 따라 예외를 던지거나, 유저 객체를 반환하는 로직을 커스텀한다.
   * @param err - Passport 전략 실행 중 발생한 시스템 에러
   * @param user - 전략의 validate() 메서드가 성공적으로 반환한 값 (보통 payload)
   * @param error - JWT 검증 실패 시 발생하는 에러(예: 토큰 만료, 서명 불일치)
   * @returns
   */
  handleRequest(err: any, user: any, error: Error) {
    if (err) throw err;
    if (error || !user) throw new UnauthorizedException('Invalid refresh token');
    return user;
  }
}
