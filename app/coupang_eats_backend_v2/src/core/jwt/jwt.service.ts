import { Injectable, UnauthorizedException } from '@nestjs/common';
import { SessionPolicy, SessionClaims } from './session-policy';
import { JwtPayload, TokenPair, DecodedToken } from './jwt.interface';
import { User } from '../../entities/user/user.entity';

// Keep the application's existing service API; every token path uses one policy.
@Injectable()
export class TokenService {
  constructor(private readonly sessions: SessionPolicy) {}

  generateTokenPair(userId: User['id']): Promise<TokenPair> {
    return this.sessions.issue(userId);
  }
  refreshTokens(refreshToken: string): Promise<TokenPair> {
    return this.sessions.refresh(refreshToken);
  }
  revokeAllUserTokens(userId: User['id'], accessToken: string): Promise<void> {
    return this.sessions.logout(accessToken, userId);
  }
  validateAccessClaims(payload: JwtPayload) {
    return this.sessions.validateAccessClaims(payload as SessionClaims);
  }
  async verifyAccessToken(token: string): Promise<DecodedToken> {
    return { payload: await this.sessions.authenticate(token), expired: false };
  }
  // Compatibility for the old guard name. No blacklist/missing-key allow path.
  // Not registered globally; callers must not turn Redis failures into success.
  async isTokenBlacklisted(token: string): Promise<boolean> {
    try { await this.sessions.authenticate(token); return false; }
    catch (error) { if (error instanceof UnauthorizedException) return true; throw error; }
  }
}
