import { TokenService } from './jwt.service';
import { Injectable, UnauthorizedException } from '@nestjs/common';
import { PassportStrategy } from '@nestjs/passport';
import { isUUID } from 'class-validator';
import { ExtractJwt, Strategy } from 'passport-jwt';
import { MoinConfigService } from '../config/config.service';
import { JwtPayload, TokenType } from './jwt.interface';
import { User } from '../../entities/user/user.entity';
import { UserRepository } from '../../modules/user/repository/user.repository';

@Injectable()
export class AccessTokenStrategy extends PassportStrategy(
  Strategy,
  'jwt-access',
) {
  constructor(
    private configService: MoinConfigService,
    private userRepository: UserRepository,
    private readonly tokenService: TokenService,
  ) {
    const jwtConfig = configService.getJwtConfig();

    // 부모 클래스 초기화
    super({
      jwtFromRequest: ExtractJwt.fromAuthHeaderAsBearerToken(), // 요청의 헤더(Authorization: Bearer <token>)에서 토큰 추출
      ignoreExpiration: false,
      algorithms: ['HS256'], // 만료된 토큰은 거부
      secretOrKey: jwtConfig.JWT_ACCESS_SECRET, // 서명 검증을 위한 비밀키 설정
    });
  }

  /**
   * 토큰 검증 로직, super()에서 서명 검증이 통과된 후 실행,
   * @param payload  - 토큰을 해독한 JSON 데이터(sub, type, iat, exp 등)
   * @returns
   */
  async validate(payload: JwtPayload): Promise<User> {
    if (
      payload?.type !== TokenType.ACCESS ||
      typeof payload.sub !== 'string' ||
      !isUUID(payload.sub)
    ) {
      throw new UnauthorizedException('Invalid token type');
    }

    await this.tokenService.validateAccessClaims(payload);
    const user = await this.userRepository.findOneByFilters({
      // 유저 확인, 토큰에 적힌 ID(sub)가 실제 DB에 존재하는지 확인(탈퇴했거나 삭제된 유저의 토큰 사용 방지)
      id: payload.sub,
    });
    if (!user) {
      throw new UnauthorizedException('User not found');
    }
    return user;
  }
}
