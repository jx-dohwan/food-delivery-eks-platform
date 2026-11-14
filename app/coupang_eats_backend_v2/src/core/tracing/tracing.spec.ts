import {
  SpanKind,
  SpanStatusCode,
  trace,
  ROOT_CONTEXT,
  TraceFlags,
} from '@opentelemetry/api';
import { ExportResultCode } from '@opentelemetry/core';
import { NodeSDK } from '@opentelemetry/sdk-node';
import {
  InMemorySpanExporter,
  SamplingDecision,
  type ReadableSpan,
} from '@opentelemetry/sdk-trace-base';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { privateSpan, PrivacyExporter } from './privacy-exporter';
import {
  boundedTraceShutdown,
  excludedTracePath,
  startTracing,
  tracingOptions,
} from './tracing';
import { TracingShutdown } from './tracing.module';

const env = {
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: 'http://adot-collector:4318/v1/traces',
};

describe('Tracing configuration and privacy (no external exporter)', () => {
  it('uses trace-only readers, fixed resource, bounded batch, five explicit instrumentations', () => {
    const options = tracingOptions(env, new InMemorySpanExporter());
    expect(options.metricReaders).toEqual([]);
    expect(options.logRecordProcessors).toEqual([]);
    expect(options.autoDetectResources).toBe(false);
    expect(options.resource.attributes).toEqual({
      'service.name': 'food-delivery-was',
      'deployment.environment.name': 'dev',
    });
    expect(options.instrumentations.map((i) => i.instrumentationName)).toEqual([
      '@opentelemetry/instrumentation-http',
      '@opentelemetry/instrumentation-express',
      '@opentelemetry/instrumentation-nestjs-core',
      '@opentelemetry/instrumentation-aws-sdk',
      '@opentelemetry/instrumentation-mysql2',
    ]);
    expect(options.instrumentations[4].getConfig()).toMatchObject({
      maskStatement: true,
      addSqlCommenterCommentToQueries: false,
    });
  });

  it.each([
    '/health',
    '/health/live',
    '/health/ready?token=secret',
    '/health/startup',
    '/health/drain',
    '/metrics/',
  ])('excludes %s', (path) => {
    expect(excludedTracePath(path)).toBe(true);
  });
  it.each(['/restaurants', '/orders/123', '/healthcheck', '/metrics-api'])(
    'keeps business path %s',
    (path) => {
      expect(excludedTracePath(path)).toBe(false);
    },
  );
  it.each([
    'https://user:secret@outside.test/v1/traces',
    'http://localhost:4318/v1/traces',
    'http://adot-collector:4318/v1/traces?token=secret',
  ])('rejects unsafe exporter URL %s', (endpoint) => {
    expect(() =>
      tracingOptions({ ...env, OTEL_EXPORTER_OTLP_TRACES_ENDPOINT: endpoint }),
    ).toThrow();
  });

  it('round trips X-Ray propagation and retains the sampled trace context', () => {
    const options = tracingOptions(env, new InMemorySpanExporter());
    const span = {
      traceId: 'abcdef12345678901234567890123456',
      spanId: '1234567890123456',
      traceFlags: TraceFlags.SAMPLED,
    };
    const carrier: Record<string, string> = {};
    options.textMapPropagator.inject(
      trace.setSpanContext(ROOT_CONTEXT, span),
      carrier,
      {
        set: (c: Record<string, string>, k: string, v: string) => {
          c[k] = v;
        },
      },
    );
    expect(carrier['x-amzn-trace-id']).toContain(
      'Root=1-abcdef12-345678901234567890123456',
    );
    const extracted = options.textMapPropagator.extract(ROOT_CONTEXT, carrier, {
      get: (c: Record<string, string>, k: string) => c[k],
      keys: (c: Record<string, string>) => Object.keys(c),
    });
    expect(trace.getSpanContext(extracted)?.traceId).toBe(span.traceId);
  });

  it('samples roots and untrusted remote sampled parents at 10%, while local children follow their parent', () => {
    const { sampler } = tracingOptions(env, new InMemorySpanExporter());
    let sampled = 0;
    for (let i = 0; i < 1000; i++) {
      const id = BigInt(i * 4294967)
        .toString(16)
        .padStart(32, '0');
      if (
        sampler.shouldSample(ROOT_CONTEXT, id, 'test', SpanKind.SERVER, {}, [])
          .decision === SamplingDecision.RECORD_AND_SAMPLED
      )
        sampled++;
    }
    // The ratio sampler folds the ID to 32 bits; use a deliberately high value.
    const remote = trace.setSpanContext(ROOT_CONTEXT, {
      traceId: '0'.repeat(24) + 'ffffffff',
      spanId: 'a'.repeat(16),
      traceFlags: 1,
      isRemote: true,
    });
    expect(
      sampler.shouldSample(
        remote,
        '0'.repeat(24) + 'ffffffff',
        'test',
        SpanKind.SERVER,
        {},
        [],
      ).decision,
    ).toBe(SamplingDecision.NOT_RECORD);
    const local = trace.setSpanContext(ROOT_CONTEXT, {
      traceId: '0'.repeat(24) + 'ffffffff',
      spanId: 'a'.repeat(16),
      traceFlags: 1,
    });
    expect(
      sampler.shouldSample(
        local,
        '0'.repeat(24) + 'ffffffff',
        'test',
        SpanKind.CLIENT,
        {},
        [],
      ).decision,
    ).toBe(SamplingDecision.RECORD_AND_SAMPLED);
    expect(sampled).toBeGreaterThanOrEqual(95);
    expect(sampled).toBeLessThanOrEqual(105);
  });

  const sensitive = 'password JWT email@example.com AWS_SECRET Slack_webhook';
  function span(attributes: ReadableSpan['attributes']): ReadableSpan {
    return {
      name: `/orders/123?${sensitive}`,
      kind: SpanKind.SERVER,
      attributes,
      status: { code: SpanStatusCode.ERROR, message: sensitive },
      events: [
        {
          name: 'exception',
          time: [1, 0],
          attributes: { 'exception.message': sensitive },
        },
      ],
      links: [],
      resource: resourceFromAttributes({
        'service.name': sensitive,
        'process.command_args': [sensitive],
      }),
      instrumentationScope: { name: 'test' },
      spanContext: () => ({
        traceId: 'a'.repeat(32),
        spanId: 'b'.repeat(16),
        traceFlags: 1,
      }),
      startTime: [1, 0],
      endTime: [1, 1],
      duration: [0, 1],
      ended: true,
      droppedAttributesCount: 0,
      droppedEventsCount: 0,
      droppedLinksCount: 0,
    };
  }
  it('exports only method/template/status; strips URL, body, headers, SQL, exceptions, resource and AWS values', () => {
    const input = span({
      'http.method': 'GET',
      'http.route': '/orders/:id',
      'http.status_code': 500,
      'http.url': sensitive,
      'url.full': sensitive,
      'http.request.header.authorization': sensitive,
      'db.statement': sensitive,
      'db.query.text': sensitive,
      'aws.s3.bucket': sensitive,
      email: sensitive,
    });
    // Real SDK SpanImpl instances also have private enumerable state and
    // prototype getters. None of that private state may cross this boundary.
    Object.assign(input, {
      _privateError: sensitive,
      _resource: { secret: sensitive },
    });
    const result = privateSpan(input);
    expect(result.name).toBe('GET /orders/:id');
    expect(result.attributes).toEqual({
      'http.method': 'GET',
      'http.route': '/orders/:id',
      'http.status_code': 500,
    });
    expect(JSON.stringify(result)).not.toContain(sensitive);
    expect(result.status.code).toBe(SpanStatusCode.ERROR);
    expect(input.events).toHaveLength(1);
    expect(privateSpan(span({ 'http.route': '/orders/123' })).name).toBe(
      'OTHER <unmatched>',
    );
    expect(
      privateSpan(span({ 'db.system': 'mysql', 'db.statement': sensitive }))
        .name,
    ).toBe('mysql.query');
    expect(
      privateSpan(
        span({
          'rpc.service': 'S3',
          'rpc.method': 'PutObject',
          'aws.s3.bucket': sensitive,
        }),
      ).name,
    ).toBe('S3.PutObject');
  });
  it('isolates a throwing exporter and does not reveal the thrown data', () => {
    const exporter = new PrivacyExporter({
      export: () => {
        throw new Error(sensitive);
      },
      shutdown: () => Promise.resolve(),
    });
    const done = jest.fn();
    expect(() => exporter.export([span({})], done)).not.toThrow();
    expect(done).toHaveBeenCalledWith({ code: ExportResultCode.FAILED });
  });
  it('fails open on disabled/invalid config and SDK initialization failure', () => {
    expect(startTracing({})).toBe(false);
    expect(
      startTracing({
        ...env,
        OTEL_TRACES_EXPORTER: 'otlp',
        OTEL_TRACES_SAMPLER_ARG: 'bad',
      }),
    ).toBe(false);
    const start = jest
      .spyOn(NodeSDK.prototype, 'start')
      .mockImplementation(() => {
        throw new Error('test');
      });
    expect(startTracing({ ...env, OTEL_TRACES_EXPORTER: 'otlp' })).toBe(false);
    start.mockRestore();
  });
  it('bounds shutdown, tolerates rejection and integrates with the Nest lifecycle', async () => {
    await expect(
      boundedTraceShutdown(() => Promise.reject(new Error(sensitive))),
    ).resolves.toBeUndefined();
    await expect(
      boundedTraceShutdown(() => new Promise(() => undefined), 10),
    ).resolves.toBeUndefined();
    await expect(
      new TracingShutdown().onApplicationShutdown(),
    ).resolves.toBeUndefined();
  });
});
