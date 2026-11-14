import { execFileSync } from 'node:child_process';
import path from 'node:path';

// The production entrypoint is compiled by npm run build before this suite.
// A fresh process proves patch ordering; the SDK exporter/AWS transport are mocks.
describe('Real automatic instrumentation, local transports only', () => {
  function fixture(args: string[] = []): {
    status: number;
    errorStatus: number;
    noise: number;
    diagnosticEvents: { error_code?: string; event?: string }[];
    spans: {
      name: string;
      kind: number;
      trace: string;
      id: string;
      parent?: string;
      status: { code: number };
      attributes: Record<string, unknown>;
    }[];
  } {
    return JSON.parse(
      execFileSync(
        process.execPath,
        [path.resolve('test/tracing/auto-instrumentation.cjs'), ...args],
        {
          timeout: 20000,
          encoding: 'utf8',
          env: {
            ...process.env,
            OTEL_TRACES_EXPORTER: 'none',
            AWS_EC2_METADATA_DISABLED: 'true',
            OTEL_LOG_LEVEL: 'none',
          },
        },
      ).trim(),
    ) as ReturnType<typeof fixture>;
  }
  it('traces Nest HTTP with S3 PutObject/SES SendEmail/outbound HTTP child spans, without sensitive values', () => {
    const result = fixture();
    expect(result.status).toBe(200);
    expect(result.errorStatus).toBe(500);
    expect(result.noise).toBe(0);
    const server = result.spans.find(
      (s) => s.name === 'GET /trace/:id' && s.kind === 1,
    );
    expect(server).toBeDefined();
    for (const name of ['S3.PutObject', 'SES.SendEmail']) {
      const span = result.spans.find((s) => s.name === name);
      expect(span).toBeDefined();
      expect(span?.trace).toBe(server?.trace);
      expect(span?.parent).toBeDefined();
    }
    expect(result.spans.some((s) => s.name.startsWith('nest.'))).toBe(true);
    expect(
      result.spans.some((s) => s.kind === 2 && s.name === 'HTTP GET'),
    ).toBe(true);
    expect(result.spans.some((s) => s.kind === 1 && s.status.code === 2)).toBe(
      true,
    );
    for (const value of [
      'PRIVATE_EMAIL',
      'SECRET_JWT',
      'SECRET_COOKIE',
      'SECRET_ERROR_WITH_PASSWORD',
      'private-test-bucket',
      'private-user',
      '/trace/123',
      'db.statement',
    ]) {
      expect(JSON.stringify(result)).not.toContain(value);
    }
  });
  it('keeps business responses successful when trace export fails', () => {
    const result = fixture(['--export-failure']);
    expect(result.diagnosticEvents).toHaveLength(1);
    expect(result.diagnosticEvents[0]).toMatchObject({ event: 'application.failed', error_code: 'OTEL_EXPORT_FAILED' });
    expect(JSON.stringify(result)).not.toContain('SECRET');
    expect(result.status).toBe(200);
    expect(result.errorStatus).toBe(500);
  });
});
