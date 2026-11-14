import type { ThrottlerStorage } from '@nestjs/throttler';
import { CacheService } from '../cache/cache.service';
import { LoggerService } from '../logger/logger.service';

export const RATE_LIMIT_SCRIPT = `
local hits = redis.call('INCR', KEYS[1])
local remaining = redis.call('PTTL', KEYS[1])
if remaining < 0 then
  redis.call('PEXPIRE', KEYS[1], ARGV[1])
  remaining = tonumber(ARGV[1])
end
return {hits, remaining}
`;

function record(totalHits: number, remaining: number, limit: number) {
  const seconds = Math.max(1, Math.ceil(remaining / 1000));
  const isBlocked = totalHits > limit;
  return {
    totalHits,
    timeToExpire: seconds,
    isBlocked,
    timeToBlockExpire: isBlocked ? seconds : 0,
  };
}

// Bounded degradation mode. No per-request timers or unbounded persistent keys.
export class MemoryRateLimitStorage implements ThrottlerStorage {
  private readonly counters = new Map<
    string,
    { hits: number; expiresAt: number }
  >();
  constructor(private readonly capacity = 10_000) {}

  increment(key: string, ttl: number, limit: number) {
    const now = Date.now();
    let counter = this.counters.get(key);
    if (!counter || counter.expiresAt <= now) {
      if (this.counters.size >= this.capacity) {
        for (const [name, entry] of this.counters) {
          if (entry.expiresAt <= now) this.counters.delete(name);
        }
        if (this.counters.size >= this.capacity) {
          const oldest = this.counters.keys().next();
          if (!oldest.done) this.counters.delete(oldest.value);
        }
      }
      counter = { hits: 0, expiresAt: now + ttl };
      this.counters.set(key, counter);
    }
    counter.hits++;
    return Promise.resolve(
      record(counter.hits, counter.expiresAt - now, limit),
    );
  }
}

export class RedisRateLimitStorage implements ThrottlerStorage {
  private readonly fallback = new MemoryRateLimitStorage();
  private unavailableUntil = 0;
  private lastWarningAt = -Infinity;

  constructor(
    private readonly cache: CacheService,
    private readonly logger: LoggerService,
  ) {}

  async increment(key: string, ttl: number, limit: number) {
    const local = await this.fallback.increment(key, ttl, limit);
    if (Date.now() < this.unavailableUntil) return local;
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      const result: unknown = await Promise.race([
        this.cache.evalRateLimit(
          RATE_LIMIT_SCRIPT,
          `food-delivery/rate-limit/v1/${key}`,
          ttl,
        ),
        new Promise<never>((_resolve, reject) => {
          timeout = setTimeout(
            () => reject(new Error('Rate-limit storage timeout')),
            250,
          );
        }),
      ]);
      if (
        !Array.isArray(result) ||
        result.length !== 2 ||
        typeof result[0] !== 'number' ||
        !Number.isSafeInteger(result[0]) ||
        result[0] < 1 ||
        typeof result[1] !== 'number' ||
        !Number.isFinite(result[1]) ||
        result[1] < 0
      ) {
        throw new Error('Invalid rate-limit storage reply');
      }
      return record(result[0], result[1], limit);
    } catch {
      this.unavailableUntil = Date.now() + 1000;
      if (Date.now() - this.lastWarningAt >= 30_000) {
        this.lastWarningAt = Date.now();
        // Never include request, Redis error text, tracker, key or credentials.
        this.logger.warn(
          'RateLimitStorage',
          { degraded: true, storage: 'memory' },
          'Rate limit storage unavailable; using local limits',
        );
      }
      return local;
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }
}
