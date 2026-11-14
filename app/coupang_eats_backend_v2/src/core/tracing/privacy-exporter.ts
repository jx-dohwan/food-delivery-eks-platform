import { telemetryFailure } from './telemetry-state';
import {
  SpanKind,
  type Attributes,
  type AttributeValue,
} from '@opentelemetry/api';
import { ExportResultCode, type ExportResult } from '@opentelemetry/core';
import { resourceFromAttributes } from '@opentelemetry/resources';
import type { ReadableSpan, SpanExporter } from '@opentelemetry/sdk-trace-base';

const METHODS = new Set([
  'GET',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'HEAD',
  'OPTIONS',
]);
const CODE_NAME = /^[A-Za-z_][A-Za-z0-9_.]{0,99}$/;
const SCOPES = new Set(
  ['http', 'express', 'nestjs-core', 'aws-sdk', 'mysql2'].map(
    (name) => `@opentelemetry/instrumentation-${name}`,
  ),
);

// Only framework route templates are accepted. Never consult url/path/target.
function routeTemplate(value: AttributeValue | undefined): string | undefined {
  if (typeof value !== 'string' || value.length > 160) return undefined;
  return /^\/(?:[A-Za-z_-]+|:[A-Za-z_][A-Za-z0-9_]*)(?:\/(?:[A-Za-z_-]+|:[A-Za-z_][A-Za-z0-9_]*))*\/?$/.test(
    value,
  ) || value === '/'
    ? value
    : undefined;
}

export function privateSpan(span: ReadableSpan): ReadableSpan {
  const source = span.attributes;
  const attributes: Attributes = {};
  const methodValue = source['http.request.method'] ?? source['http.method'];
  const method =
    typeof methodValue === 'string' && METHODS.has(methodValue)
      ? methodValue
      : 'OTHER';
  const route = routeTemplate(source['http.route']);
  if (method !== 'OTHER') attributes['http.method'] = method;
  if (route) attributes['http.route'] = route;
  const status =
    source['http.response.status_code'] ?? source['http.status_code'];
  if (typeof status === 'number' && status >= 100 && status <= 599)
    attributes['http.status_code'] = status;

  const service = source['rpc.service'];
  const operation = source['rpc.method'];
  const aws =
    typeof service === 'string' &&
    /^(S3|SES|STS)$/.test(service) &&
    typeof operation === 'string' &&
    CODE_NAME.test(operation);
  if (aws) {
    attributes['rpc.system'] = 'aws-api';
    attributes['rpc.service'] = service;
    attributes['rpc.method'] = operation;
    attributes['aws.operation'] = operation;
  }
  const database =
    source['db.system'] === 'mysql' || source['db.system.name'] === 'mysql';
  if (database) attributes['db.system'] = 'mysql';
  const controller = source['nestjs.controller'];
  const callback = source['nestjs.callback'];
  const code = [controller, callback].filter(
    (v): v is string => typeof v === 'string' && CODE_NAME.test(v),
  );
  const name = aws
    ? `${service}.${operation}`
    : database
      ? 'mysql.query'
      : span.kind === SpanKind.SERVER
        ? `${method} ${route ?? '<unmatched>'}`
        : code.length
          ? `nest.${code.join('.')}`
          : span.kind === SpanKind.CLIENT
            ? `HTTP ${method}`
            : 'framework.handler';

  return {
    name,
    kind: span.kind,
    startTime: span.startTime,
    endTime: span.endTime,
    duration: span.duration,
    ended: span.ended,
    droppedAttributesCount: span.droppedAttributesCount,
    droppedEventsCount: span.droppedEventsCount,
    droppedLinksCount: span.droppedLinksCount,
    spanContext: () => {
      const { traceId, spanId, traceFlags } = span.spanContext();
      return { traceId, spanId, traceFlags };
    },
    parentSpanContext: span.parentSpanContext
      ? {
          traceId: span.parentSpanContext.traceId,
          spanId: span.parentSpanContext.spanId,
          traceFlags: span.parentSpanContext.traceFlags,
        }
      : undefined,
    attributes,
    status: { code: span.status.code },
    // Exception events/stacks, link attributes and SDK metadata can contain SQL,
    // request bodies, email, AWS identifiers or signed URLs. Export none of them.
    events: [],
    links: [],
    resource: resourceFromAttributes({
      'service.name': 'food-delivery-was',
      'deployment.environment.name':
        span.resource.attributes['deployment.environment.name'] === 'prod'
          ? 'prod'
          : 'dev',
    }),
    instrumentationScope: {
      name: SCOPES.has(span.instrumentationScope.name)
        ? span.instrumentationScope.name
        : 'food-delivery-was',
    },
  };
}

// Privacy boundary is BEFORE OTLP serialization/transport. SDK span objects are
// never mutated; unknown future instrumentation attributes are omitted by default.
export class PrivacyExporter implements SpanExporter {
  constructor(private readonly delegate: SpanExporter) {}

  export(
    spans: ReadableSpan[],
    callback: (result: ExportResult) => void,
  ): void {
    try {
      this.delegate.export(spans.map(privateSpan), (result) => {
        if (result.code !== ExportResultCode.SUCCESS) telemetryFailure('export');
        callback(result);
      });
    } catch {
      telemetryFailure('export');
      callback({ code: ExportResultCode.FAILED });
    }
  }
  shutdown(): Promise<void> {
    return this.delegate.shutdown();
  }
  forceFlush(): Promise<void> {
    return this.delegate.forceFlush?.() ?? Promise.resolve();
  }
}
