import { Test } from '@nestjs/testing';
import { getStorageToken, type ThrottlerStorage } from '@nestjs/throttler';
import { RateLimitModule } from './rate-limit.module';
import { RedisRateLimitStorage, RATE_LIMIT_SCRIPT } from './rate-limit.storage';
import { RedisClientKey } from '../cache/cache.interface';
import { MoinConfigService } from '../config/config.service';
import { LoggerService } from '../logger/logger.service';
import { Env } from '../config';

describe('production rate module dependency wiring', () => {
  it('uses the existing CacheService Redis connection as Throttler storage', async () => {
    const evalScript = jest.fn(() => Promise.resolve([1, 60_000]));
    const module = await Test.createTestingModule({
      imports: [RateLimitModule],
    })
      .overrideProvider(RedisClientKey)
      .useValue({
        status: 'ready',
        eval: evalScript,
        quit: jest.fn().mockResolvedValue('OK'),
        disconnect: jest.fn(),
      })
      .overrideProvider(MoinConfigService)
      .useValue({
        getAppConfig: () => ({ ENV: Env.test, NAME: 'rate-limit-test' }),
      })
      .overrideProvider(LoggerService)
      .useValue({ warn: jest.fn(), info: jest.fn(), error: jest.fn() })
      .compile();
    try {
      await module.init();
      const storage = module.get<ThrottlerStorage>(getStorageToken());
      expect(storage).toBeInstanceOf(RedisRateLimitStorage);
      expect(
        (await storage.increment('hash', 60_000, 2, 60_000, 'default'))
          .isBlocked,
      ).toBe(false);
      expect(evalScript).toHaveBeenCalledWith(
        RATE_LIMIT_SCRIPT,
        1,
        'food-delivery/rate-limit/v1/hash',
        60_000,
      );
    } finally {
      await module.close();
    }
  });
});
