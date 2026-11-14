import { Module } from '@nestjs/common';
import { ThrottlerModule } from '@nestjs/throttler';
import { CacheModule } from '../cache/cache.module';
import { CacheService } from '../cache/cache.service';
import { CacheServiceKey } from '../cache/cache.interface';
import { LoggerModule } from '../logger/logger.module';
import { LoggerService } from '../logger/logger.service';
import { rateLimitOptions } from './rate-limit.policy';
import { RedisRateLimitStorage } from './rate-limit.storage';

@Module({
  imports: [
    ThrottlerModule.forRootAsync({
      imports: [CacheModule, LoggerModule],
      inject: [CacheServiceKey, LoggerService],
      useFactory: (cache: CacheService, logger: LoggerService) => ({
        ...rateLimitOptions(),
        storage: new RedisRateLimitStorage(cache, logger),
      }),
    }),
  ],
  exports: [ThrottlerModule],
})
export class RateLimitModule {}
