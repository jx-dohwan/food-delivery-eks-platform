import { writeEvent } from '../logger/safe-event';

type FailureStage = 'sdk_start' | 'export';
// Plain state deliberately avoids loading prom-client/http before instrumentation.
export const telemetryState = {
  enabled: false,
  active: false,
  failures: { sdk_start: 0, export: 0 },
};
const lastWarning: Partial<Record<FailureStage, number>> = {};
export function telemetryFailure(stage: FailureStage): void {
  telemetryState.failures[stage]++;
  const now = Date.now();
  if (lastWarning[stage] === undefined || now - lastWarning[stage]! >= 60_000) {
    lastWarning[stage] = now;
    writeEvent('application.failed', 'WARN', {
      error_code: stage === 'sdk_start' ? 'OTEL_START_FAILED' : 'OTEL_EXPORT_FAILED',
    });
  }
}
