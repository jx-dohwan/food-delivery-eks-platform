import { DataSource } from 'typeorm';
import { createInitializedDataSource } from '../database/typeorm/typeorm.module';
import { addTransactionalDataSource } from 'typeorm-transactional';
import { safeEvent, errorFields } from './safe-event';
import { SafeTypeOrmLogger } from './safe-typeorm.logger';
import { telemetryFailure, telemetryState } from '../tracing/telemetry-state';
import { MetricsService } from '../metrics/metrics.service';
import { PrivacyExporter } from '../tracing/privacy-exporter';
import { ExportResultCode } from '@opentelemetry/core';

jest.mock('typeorm-transactional', () => ({
  addTransactionalDataSource: jest.fn((source) => source),
  initializeTransactionalContext: jest.fn(), deleteDataSourceByName: jest.fn(),
}));
const options = { type: 'mysql' as const };
describe('U04 real producers and safe telemetry boundary', () => {
  let output: string[];
  beforeEach(() => {
    output = [];
    jest.spyOn(process.stdout, 'write').mockImplementation((v: any) => { output.push(String(v)); return true; });
    jest.spyOn(process.stderr, 'write').mockImplementation((v: any) => { output.push(String(v)); return true; });
  });
  afterEach(() => jest.restoreAllMocks());
  it('does not report ready while initialization is pending; registers only after success', async () => {
    let complete!: (value: DataSource) => void;
    jest.spyOn(DataSource.prototype, 'initialize').mockImplementation(function () { return new Promise((r) => { complete = () => r(this); }); });
    const pending = createInitializedDataSource(options);
    expect(output).toEqual([]);
    expect(addTransactionalDataSource).not.toHaveBeenCalled();
    complete({} as DataSource); await pending;
    expect(JSON.parse(output[0])).toMatchObject({ event: 'database.ready', phase: 'startup' });
  });
  it('logs a real initialization rejection safely and preserves its error semantics', async () => {
    const error = Object.assign(new Error('SYNTHETIC_PASSWORD_AUTH_URL'), { code: 'ER_ACCESS_DENIED_ERROR' });
    jest.spyOn(DataSource.prototype, 'initialize').mockRejectedValue(error);
    await expect(createInitializedDataSource(options)).rejects.toBe(error);
    const event = JSON.parse(output[0]);
    expect(event).toMatchObject({event: 'database.failed', phase: 'startup', error_code: 'ER_ACCESS_DENIED_ERROR'});
    expect(output.join('')).not.toContain('SYNTHETIC');
    expect(output.join('')).not.toContain('database.ready');
  });
  it('keeps phase bounded, accepts legacy no-phase logs and only unwraps allowlisted driver codes', () => {
    expect(errorFields({ name: 'QueryFailedError', driverError: {code: 'ER_LOCK_DEADLOCK', message: 'SECRET'} })).toEqual({error_type: 'QueryFailedError', error_code: 'ER_LOCK_DEADLOCK'});
    expect(errorFields({driverError: {code: 'PRIVATE_EMAIL'}})).toEqual({error_type: 'OtherError'});
    expect(safeEvent('database.failed', 'ERROR', {phase: 'query'})).toHaveProperty('phase', 'query');
    expect(safeEvent('database.failed', 'ERROR', {phase: 'SECRET'})).not.toHaveProperty('phase');
    expect(safeEvent('database.failed')).not.toHaveProperty('phase');
  });
  it('migration notices never masquerade as readiness; query exceptions have phase', () => {
    const logger = new SafeTypeOrmLogger(); logger.logMigration('SECRET');
    expect(output).toEqual([]);
    logger.logQueryError(Object.assign(new Error('SECRET SQL'), {code: 'ETIMEDOUT'}));
    expect(JSON.parse(output[0])).toMatchObject({event:'database.failed', phase:'query', error_code:'ETIMEDOUT'});
    expect(output[0]).not.toContain('SECRET');
  });
  it('counts all export failures but rate-limits fixed safe warnings; no raw errors escape', async () => {
    const before = telemetryState.failures.export;
    const exporter = new PrivacyExporter({export: (_s, cb) => cb({code: ExportResultCode.FAILED, error: new Error('SECRET URL')}), shutdown: async () => undefined});
    exporter.export([], () => undefined); exporter.export([], () => undefined);
    expect(telemetryState.failures.export).toBe(before+2);
    expect(output.length).toBeLessThanOrEqual(1);
    expect(output.join('')).not.toContain('SECRET');
    const metrics = new MetricsService(); telemetryState.enabled = true; telemetryState.active = false;
    const text = await metrics.registry.metrics();
    expect(text).toContain('food_delivery_tracing_enabled 1');
    expect(text).toContain('food_delivery_tracing_active 0');
    expect(text).toContain(`food_delivery_telemetry_failures_total{stage="export"} ${before+2}`);
    const again = await metrics.registry.metrics(); expect(again).toContain(`stage="export"} ${before+2}`);
    metrics.registry.clear();
  });
});
