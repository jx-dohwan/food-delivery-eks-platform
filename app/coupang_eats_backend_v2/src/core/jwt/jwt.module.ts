import type Redis from 'ioredis';
import { DataSource } from 'typeorm';
import { MysqlSessionAuthority, SessionAuthority } from './session-authority';
import { CacheModule } from '../cache/cache.module';
import { RedisClientKey } from '../cache/cache.interface';
import { ConfigModule } from '../config/config.module';
import { MoinConfigService } from '../config/config.service';
import { JwtService } from '@nestjs/jwt';
import { SessionPolicy, SessionStore } from './session-policy';
import { Global, Module } from '@nestjs/common';
import { JwtModule as NestJwtModule } from '@nestjs/jwt';
import { TokenService } from './jwt.service';
import { UserRepositoryModule } from '../../modules/user/repository/user-repository.module';
import { RefreshTokenStrategy } from './refreshToken.strategy';
import { AccessTokenStrategy } from './accessToken.strategy';

@Global()
@Module({
  imports: [NestJwtModule.register({}), UserRepositoryModule, CacheModule, ConfigModule],
  providers: [TokenService, AccessTokenStrategy, RefreshTokenStrategy,
    { provide: SessionAuthority, useFactory: (source: DataSource) => new MysqlSessionAuthority(source), inject: [DataSource] },
    { provide: SessionStore, useFactory: (redis: Redis, authority: SessionAuthority) => new SessionStore(redis, authority), inject: [RedisClientKey, SessionAuthority] },
    { provide: SessionPolicy, useFactory: (jwt: JwtService, store: SessionStore, config: MoinConfigService) => {
      const c = config.getJwtConfig();
      return new SessionPolicy(jwt, store, { accessSecret: c.JWT_ACCESS_SECRET, refreshSecret: c.JWT_REFRESH_SECRET,
        accessSeconds: tokenDurationSeconds(c.JWT_ACCESS_EXPIRATION), refreshSeconds: tokenDurationSeconds(c.JWT_REFRESH_EXPIRATION) });
    }, inject: [JwtService, SessionStore, MoinConfigService] },
  ],
  exports: [TokenService],
})
export class JwtModule {}

// Preserve configured lifetimes; reject an ambiguous value instead of a fallback.
export function tokenDurationSeconds(value: string): number {
  const match = /^(\d+)([smhd])$/.exec(value);
  if (!match) throw new Error('Invalid token expiration configuration');
  const n = Number(match[1]) * ({ s: 1, m: 60, h: 3600, d: 86400 }[match[2]]!);
  if (!Number.isSafeInteger(n) || n <= 0) throw new Error('Invalid token expiration configuration');
  return n;
}
