import { errorFields, writeEvent } from '../logger/safe-event';
import { Inject, Injectable } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { CacheServiceKey } from '../cache/cache.interface';
import { CacheService } from '../cache/cache.service';
import { WorkloadLifecycleService } from './workload-lifecycle.service';

const CHECK_TIMEOUT_MS = 1_000;
const CACHE_MS = 2_000;

@Injectable()
export class HealthService {
  private dependencyWork?: Promise<boolean>;
  private cachedResult?: Promise<boolean>;
  private cacheUntil = 0;
  private databaseHealthy?: boolean;

  constructor(
    private readonly dataSource: DataSource,
    @Inject(CacheServiceKey) private readonly cache: CacheService,
    private readonly lifecycle: WorkloadLifecycleService,
  ) {}

  async isReady(): Promise<boolean> {
    if (!this.lifecycle.hasStarted || this.lifecycle.isDraining) return false;
    if (!this.cachedResult || Date.now() >= this.cacheUntil) {
      this.cacheUntil = Infinity;
      this.cachedResult = this.checkDependencies().then((healthy) => {
        this.cacheUntil = Date.now() + CACHE_MS;
        return healthy;
      });
    }
    const healthy = await this.cachedResult;
    return healthy && !this.lifecycle.isDraining;
  }

  private observeDatabase(healthy: boolean, error?: unknown): void {
    // Only transitions: no repeated health-check error floods or raw error data.
    if (healthy !== this.databaseHealthy && (!healthy || this.databaseHealthy === false)) {
      writeEvent(healthy ? 'database.ready' : 'database.failed', healthy ? 'INFO' : 'ERROR',
        { phase: 'health', ...(!healthy ? errorFields(error) : {}) });
    }
    this.databaseHealthy = healthy;
  }

  private async checkDependencies(): Promise<boolean> {
    if (!this.dataSource.isInitialized) return false;
    // A timeout bounds the probe response, not the driver's pending I/O.
    // Keep one underlying check until BOTH operations settle, even on failure:
    // repeated anonymous probes cannot accumulate pool/Redis checks in an outage.
    if (!this.dependencyWork) {
      const work = Promise.allSettled([
        this.dataSource.query('SELECT 1').then(
          (value) => { this.observeDatabase(true); return value; },
          (error: unknown) => { this.observeDatabase(false, error); throw error; },
        ),
        this.cache.pingReady(),
      ]).then((results) => results.every((r) => r.status === 'fulfilled'));
      this.dependencyWork = work;
      void work.then(() => {
        this.dependencyWork = undefined;
      });
    }
    let timeout: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        this.dependencyWork,
        new Promise<boolean>((resolve) => {
          timeout = setTimeout(() => resolve(false), CHECK_TIMEOUT_MS);
          timeout.unref();
        }),
      ]);
    } finally {
      if (timeout) clearTimeout(timeout);
    }
  }
}
