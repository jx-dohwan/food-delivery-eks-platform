import type { DataSource } from 'typeorm';
import { CacheService } from '../cache/cache.service';
import { HealthService } from './health.service';
import { WorkloadLifecycleService } from './workload-lifecycle.service';
import { SafeConsoleLogger } from '../logger/safe-console.logger';

describe('Readiness dependency checks', () => {
  const db = { isInitialized: true, query: jest.fn() };
  const cache = { pingReady: jest.fn() };
  let lifecycle: WorkloadLifecycleService;
  let health: HealthService;
  beforeEach(() => {
    jest.useFakeTimers();
    jest.spyOn(SafeConsoleLogger.prototype, 'log').mockImplementation(() => {});
    db.isInitialized = true;
    db.query.mockReset().mockResolvedValue([{ 1: 1 }]);
    cache.pingReady.mockReset().mockResolvedValue(undefined);
    lifecycle = new WorkloadLifecycleService();
    lifecycle.onApplicationBootstrap();
    health = new HealthService(
      db as unknown as DataSource,
      cache as unknown as CacheService,
      lifecycle,
    );
  });
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  it('checks DB SELECT 1 and Redis, sharing cached checks between probes', async () => {
    expect(await health.isReady()).toBe(true);
    expect(await health.isReady()).toBe(true);
    expect(db.query).toHaveBeenCalledTimes(1);
    expect(db.query).toHaveBeenCalledWith('SELECT 1');
    expect(cache.pingReady).toHaveBeenCalledTimes(1);
  });

  it.each(['db', 'redis'])(
    'returns not ready for %s failure without exposing the error',
    async (dependency) => {
      const target = dependency === 'db' ? db.query : cache.pingReady;
      target.mockRejectedValue(new Error('SECRET_PASSWORD DB_HOST token'));
      expect(await health.isReady()).toBe(false);
    },
  );

  it('bounds hung checks and never accumulates queries, even when Redis fails first', async () => {
    db.query.mockImplementation(() => new Promise(() => {}));
    cache.pingReady.mockRejectedValue(new Error('Redis unavailable'));
    const first = health.isReady();
    await jest.advanceTimersByTimeAsync(1_000);
    expect(await first).toBe(false);
    await jest.advanceTimersByTimeAsync(2_001);
    const second = health.isReady();
    await jest.advanceTimersByTimeAsync(1_000);
    expect(await second).toBe(false);
    expect(db.query).toHaveBeenCalledTimes(1);
    expect(cache.pingReady).toHaveBeenCalledTimes(1);
  });

  it('rechecks dependencies after the cache window and recovers', async () => {
    db.query.mockRejectedValueOnce(new Error('Unavailable'));
    expect(await health.isReady()).toBe(false);
    await jest.advanceTimersByTimeAsync(2_001);
    expect(await health.isReady()).toBe(true);
  });

  it('is immediately not ready during drain, even after a cached success', async () => {
    expect(await health.isReady()).toBe(true);
    lifecycle.beginDrain();
    expect(await health.isReady()).toBe(false);
    expect(db.query).toHaveBeenCalledTimes(1);
  });

  it('does not check an uninitialized datasource', async () => {
    db.isInitialized = false;
    expect(await health.isReady()).toBe(false);
    expect(db.query).not.toHaveBeenCalled();
  });

  it('is not ready before Nest bootstrap completes', async () => {
    const starting = new HealthService(
      db as unknown as DataSource,
      cache as unknown as CacheService,
      new WorkloadLifecycleService(),
    );
    expect(await starting.isReady()).toBe(false);
    expect(db.query).not.toHaveBeenCalled();
  });
});
