import type { Logger } from 'typeorm';
import { errorFields, writeEvent } from './safe-event';
export class SafeTypeOrmLogger implements Logger {
  logQuery(_query?: string, _parameters?: unknown[]): void {}
  logQueryError(error: string | Error, _query?: string, _parameters?: unknown[]): void { writeEvent('database.failed', 'ERROR', { ...errorFields(error), phase: 'query' }); }
  logQuerySlow(time: number, _query?: string, _parameters?: unknown[]): void { writeEvent('database.slow', 'WARN', { duration_ms: time }); }
  logSchemaBuild(_message?: string): void {}
  logMigration(_message?: string): void {} // Migration notices are not connection readiness.
  log(level: 'log' | 'info' | 'warn', _message?: unknown): void { if (level === 'warn') writeEvent('database.failed', 'WARN'); }
}
