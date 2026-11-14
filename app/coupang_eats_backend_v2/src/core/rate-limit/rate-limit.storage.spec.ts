import { Redis } from 'ioredis';
import { CacheService } from '../cache/cache.service';
import { LoggerService } from '../logger/logger.service';
import {
  MemoryRateLimitStorage,
  RedisRateLimitStorage,
  RATE_LIMIT_SCRIPT,
} from './rate-limit.storage';

describe('fixed-window rate storage', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(new Date('2026-10-13T00:00:00Z'));
  });
  afterEach(() => jest.useRealTimers());

  it('blocks at limit + 1 and allows again when the original window expires', async () => {
    const store = new MemoryRateLimitStorage();
    expect((await store.increment('A', 60_000, 2)).isBlocked).toBe(false);
    expect((await store.increment('A', 60_000, 2)).isBlocked).toBe(false);
    jest.advanceTimersByTime(30_000);
    expect(await store.increment('A', 60_000, 2)).toEqual({
      totalHits: 3,
      timeToExpire: 30,
      isBlocked: true,
      timeToBlockExpire: 30,
    });
    jest.advanceTimersByTime(30_000);
    expect((await store.increment('A', 60_000, 2)).totalHits).toBe(1);
  });
  it('isolates keys and bounds fallback state', async () => {
    const store = new MemoryRateLimitStorage(2);
    await store.increment('A', 1000, 1);
    await store.increment('A', 1000, 1);
    expect((await store.increment('B', 1000, 1)).isBlocked).toBe(false);
    await store.increment('C', 1000, 1);
    expect((await store.increment('A', 1000, 1)).totalHits).toBe(1);
  });
  it('two Pod adapters consume one shared atomic counter', async () => {
    // Models Redis EVAL's atomic INCR+TTL reply; no AWS Redis is contacted.
    let hits = 0;
    const evalRateLimit = jest.fn(() => Promise.resolve([++hits, 60_000]));
    const cache = { evalRateLimit } as unknown as CacheService;
    const logger = { warn: jest.fn() } as unknown as LoggerService;
    const podA = new RedisRateLimitStorage(cache, logger);
    const podB = new RedisRateLimitStorage(cache, logger);
    expect((await podA.increment('shared-hash', 60_000, 2)).isBlocked).toBe(
      false,
    );
    expect((await podB.increment('shared-hash', 60_000, 2)).isBlocked).toBe(
      false,
    );
    expect((await podA.increment('shared-hash', 60_000, 2)).isBlocked).toBe(
      true,
    );
    expect(evalRateLimit).toHaveBeenCalledWith(
      RATE_LIMIT_SCRIPT,
      'food-delivery/rate-limit/v1/shared-hash',
      60_000,
    );
  });
  it('keeps local limits during Redis failure and never logs raw errors', async () => {
    const warn = jest.fn();
    const evalRateLimit = jest.fn(() =>
      Promise.reject(new Error('PASSWORD SECRET JWT COOKIE')),
    );
    const store = new RedisRateLimitStorage(
      { evalRateLimit } as unknown as CacheService,
      { warn } as unknown as LoggerService,
    );
    expect((await store.increment('opaque-hash', 60_000, 1)).isBlocked).toBe(
      false,
    );
    expect((await store.increment('opaque-hash', 60_000, 1)).isBlocked).toBe(
      true,
    );
    expect(evalRateLimit).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(warn.mock.calls)).not.toMatch(
      /PASSWORD|SECRET|JWT|COOKIE|opaque-hash/,
    );
    expect(warn).toHaveBeenCalledTimes(1);
  });
  it('bounds Redis delay and resumes shared storage after the cooldown', async () => {
    const evalRateLimit = jest
      .fn<Promise<unknown>, unknown[]>()
      .mockImplementationOnce(() => new Promise(() => {}))
      .mockResolvedValue([5, 60_000]);
    const store = new RedisRateLimitStorage(
      { evalRateLimit } as unknown as CacheService,
      { warn: jest.fn() } as unknown as LoggerService,
    );
    const pending = store.increment('hash', 60_000, 10);
    await jest.advanceTimersByTimeAsync(250);
    expect((await pending).totalHits).toBe(1);
    jest.advanceTimersByTime(1000);
    expect((await store.increment('hash', 60_000, 10)).totalHits).toBe(5);
  });
  it.each([null, ['invalid', 60_000], [1, -1]])(
    'falls back on an invalid Redis reply: %p',
    async (reply) => {
      const store = new RedisRateLimitStorage(
        {
          evalRateLimit: () => Promise.resolve(reply),
        } as unknown as CacheService,
        { warn: jest.fn() } as unknown as LoggerService,
      );
      expect((await store.increment('hash', 60_000, 10)).totalHits).toBe(1);
    },
  );
  it('does not queue writes on a disconnected Redis connection', async () => {
    const redis = { status: 'reconnecting', eval: jest.fn() };
    const service = new CacheService(redis as unknown as Redis);
    await expect(
      service.evalRateLimit(RATE_LIMIT_SCRIPT, 'hash', 1000),
    ).rejects.toThrow();
    expect(redis.eval).not.toHaveBeenCalled();
  });
});
