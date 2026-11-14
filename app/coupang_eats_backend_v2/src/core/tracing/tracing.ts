import { diag } from '@opentelemetry/api';
import {
  CompositePropagator,
  W3CTraceContextPropagator,
} from '@opentelemetry/core';
import { NodeSDK } from '@opentelemetry/sdk-node';
import {
  BatchSpanProcessor,
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
  type SpanExporter,
} from '@opentelemetry/sdk-trace-base';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import {
  ExpressInstrumentation,
  ExpressLayerType,
} from '@opentelemetry/instrumentation-express';
import { NestInstrumentation } from '@opentelemetry/instrumentation-nestjs-core';
import { AwsInstrumentation } from '@opentelemetry/instrumentation-aws-sdk';
import { MySQL2Instrumentation } from '@opentelemetry/instrumentation-mysql2';
import { AWSXRayPropagator } from '@opentelemetry/propagator-aws-xray';
import { AWSXRayIdGenerator } from '@opentelemetry/id-generator-aws-xray';
import { telemetryFailure, telemetryState } from './telemetry-state';
import { PrivacyExporter } from './privacy-exporter';

let sdk: NodeSDK | undefined;
let closing: Promise<void> | undefined;
export const TRACE_SHUTDOWN_TIMEOUT_MS = 3000;

export function excludedTracePath(url: string | undefined): boolean {
  const path = (url ?? '').split('?')[0];
  return /^\/(?:health(?:\/.*)?|metrics\/?)$/i.test(path);
}

export function tracingOptions(
  env: NodeJS.ProcessEnv,
  exporter?: SpanExporter,
) {
  const endpoint = env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT;
  // Accept only the internal collector, never a URL with credentials/query or a
  // caller-supplied arbitrary telemetry destination.
  if (
    !endpoint ||
    !/^http:\/\/adot-collector(?:(?:\.app|\.app-prod)\.svc(?:\.cluster\.local)?)?:4318\/v1\/traces$/.test(
      endpoint,
    )
  ) {
    throw new Error('Invalid internal tracing endpoint');
  }
  const ratio = Number(env.OTEL_TRACES_SAMPLER_ARG ?? '0.1');
  if (!Number.isFinite(ratio) || ratio < 0 || ratio > 1)
    throw new Error('Invalid trace sampling ratio');
  const sampler = new TraceIdRatioBasedSampler(ratio);
  return {
    autoDetectResources: false,
    resource: resourceFromAttributes({
      'service.name': 'food-delivery-was',
      'deployment.environment.name': env.NODE_ENV === 'prod' ? 'prod' : 'dev',
    }),
    // Empty readers/processors suppress the SDK's automatic metrics/log exporters.
    metricReaders: [],
    logRecordProcessors: [],
    sampler: new ParentBasedSampler({
      root: sampler,
      remoteParentSampled: sampler,
    }),
    idGenerator: new AWSXRayIdGenerator(),
    textMapPropagator: new CompositePropagator({
      propagators: [new W3CTraceContextPropagator(), new AWSXRayPropagator()],
    }),
    spanProcessors: [
      new BatchSpanProcessor(
        new PrivacyExporter(
          exporter ??
            new OTLPTraceExporter({
              url: endpoint,
              timeoutMillis: 1000,
              concurrencyLimit: 1,
            }),
        ),
        {
          maxQueueSize: 512,
          maxExportBatchSize: 64,
          scheduledDelayMillis: 2000,
          exportTimeoutMillis: 1500,
        },
      ),
    ],
    instrumentations: [
      new HttpInstrumentation({
        ignoreIncomingRequestHook: (request) => excludedTracePath(request.url),
        requireParentforOutgoingSpans: true,
        headersToSpanAttributes: {},
      }),
      new ExpressInstrumentation({
        ignoreLayersType: [ExpressLayerType.MIDDLEWARE],
      }),
      new NestInstrumentation(),
      new AwsInstrumentation({ suppressInternalInstrumentation: true }),
      new MySQL2Instrumentation({
        maskStatement: true,
        maskStatementHook: () => '[omitted]',
        addSqlCommenterCommentToQueries: false,
      }),
    ],
  };
}

export function startTracing(env = process.env): boolean {
  if (sdk) return true;
  telemetryState.enabled = env.OTEL_TRACES_EXPORTER === 'otlp' && env.OTEL_SDK_DISABLED !== 'true';
  if (env.OTEL_TRACES_EXPORTER !== 'otlp' || env.OTEL_SDK_DISABLED === 'true')
    return false;
  try {
    // Never print raw SDK diagnostics (failed export errors can contain metadata).
    process.env.OTEL_LOG_LEVEL = 'none';
    diag.disable();
    const candidate = new NodeSDK(tracingOptions(env));
    candidate.start();
    sdk = candidate;
    telemetryState.active = true;
    return true;
  } catch {
    telemetryState.active = false;
    telemetryFailure('sdk_start');
    // Tracing is fail-open. No business request depends on collector availability.
    return false;
  }
}

export function boundedTraceShutdown(
  shutdown: () => Promise<void>,
  timeoutMs = TRACE_SHUTDOWN_TIMEOUT_MS,
): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, timeoutMs);
    Promise.resolve()
      .then(shutdown)
      .catch(() => undefined)
      .finally(() => {
        clearTimeout(timer);
        resolve();
      });
  });
}

export function shutdownTracing(): Promise<void> {
  if (!sdk) return Promise.resolve();
  const current = sdk;
  closing ??= boundedTraceShutdown(() => current.shutdown()).finally(() => { telemetryState.active = false; });
  return closing;
}
