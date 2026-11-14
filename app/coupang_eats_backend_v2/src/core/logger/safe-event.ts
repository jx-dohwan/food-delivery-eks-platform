import { context, trace, isSpanContextValid } from '@opentelemetry/api';

// Positive schema: free text, request bodies, query strings and unknown fields are discarded.
export const EVENTS = {
  'http.exception': 'HTTP exception handled', 'http.completed': 'HTTP request completed', 'http.failed': 'HTTP request failed',
  'auth.succeeded': 'Authentication operation succeeded', 'auth.failed': 'Authentication operation rejected',
  'access.denied': 'Resource access denied',
  'database.failed': 'Database operation failed', 'database.slow': 'Database operation exceeded threshold',
  'database.ready': 'Database initialization completed',
  'redis.failed': 'Cache operation failed', 'redis.ready': 'Cache connection ready',
  's3.uploaded': 'Private object uploaded', 's3.failed': 'Private object upload failed',
  'ses.accepted': 'Email service accepted request', 'ses.failed': 'Email service request failed',
  'application.started': 'Application started', 'application.stopping': 'Application shutdown started',
  'application.notice': 'Application diagnostic event', 'application.failed': 'Application operation failed',
  'framework.notice': 'Framework lifecycle event', 'framework.failed': 'Framework operation failed',
} as const;
export type EventName = keyof typeof EVENTS;
export type EventLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';
const ERROR_TYPES = new Set(['Error', 'TypeError', 'RangeError', 'QueryFailedError', 'TimeoutError',
  'ConnectionError', 'S3ServiceException', 'SESServiceException', 'UnauthorizedException',
  'ForbiddenException', 'BadRequestException', 'InternalServerErrorException', 'ServiceUnavailableException']);
const ERROR_CODES = new Set(['AUTH_SESSION_MISSING', 'AUTH_SESSION_INVALID', 'AUTH_REFRESH_REJECTED', 'AUTH_SESSION_REVOKED','ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND',
  'ER_ACCESS_DENIED_ERROR', 'ER_CON_COUNT_ERROR', 'ER_LOCK_DEADLOCK',
  'OTEL_START_FAILED', 'OTEL_EXPORT_FAILED', 'AccessDenied', 'SlowDown', 'NoSuchBucket', 'RequestTimeout', 'TimeoutError']);
const METHODS = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS']);
export function errorFields(error: unknown): Record<string, string> {
  try {
    const obj = error as { name?: string; code?: string; driverError?: { code?: string } };
    const code = ERROR_CODES.has(obj?.code ?? '') ? obj.code : obj?.driverError?.code;
    return { error_type: ERROR_TYPES.has(obj?.name ?? '') ? obj.name! : 'OtherError',
      ...(ERROR_CODES.has(code ?? '') ? { error_code: code! } : {}) };
  } catch { return { error_type: 'OtherError' }; }
}
export function activeTrace(): Record<string, string> {
  const span = trace.getSpan(context.active())?.spanContext();
  return span && isSpanContextValid(span) ? { trace_id: span.traceId, span_id: span.spanId } : {};
}
export function safeEvent(event: EventName, level: EventLevel = 'INFO', fields: Record<string, unknown> = {}) {
  const record: Record<string, unknown> = {
    timestamp: new Date().toISOString(), level, service: 'was',
    environment: ['local', 'test', 'dev', 'prod'].includes(process.env.NODE_ENV ?? process.env.ENV ?? '') ? (process.env.NODE_ENV ?? process.env.ENV) : 'unknown',
    event: Object.hasOwn(EVENTS, event) ? event : 'application.notice',
    message: Object.hasOwn(EVENTS, event) ? EVENTS[event] : EVENTS['application.notice'],
  };
  const version = process.env.DEPLOYMENT_VERSION;
  if (version && /^[a-f0-9]{40}$/.test(version)) record.deployment_version = version;
  for (const key of ['request_id', 'trace_id', 'span_id']) {
    const value = fields[key];
    const re = key === 'request_id' ? /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i : key === 'trace_id' ? /^[a-f0-9]{32}$/ : /^[a-f0-9]{16}$/;
    if (typeof value === 'string' && re.test(value)) record[key] = value;
  }
  if (typeof fields.http_method === 'string' && METHODS.has(fields.http_method)) record.http_method = fields.http_method;
  // Callers must supply Express' resolved route pattern, never request.path/url.
  if (typeof fields.http_route === 'string' && (fields.http_route === 'unmatched' || /^\/[a-zA-Z0-9/_:*-]{0,160}$/.test(fields.http_route))) record.http_route = fields.http_route;
  for (const key of ['status_code', 'duration_ms']) {
    const value = fields[key];
    if (typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= (key === 'status_code' ? 599 : 86400000)) record[key] = Math.round(value * 1000) / 1000;
  }
  if (typeof fields.error_type === 'string' && (ERROR_TYPES.has(fields.error_type) || fields.error_type === 'OtherError')) record.error_type = fields.error_type;
  if (typeof fields.error_code === 'string' && ERROR_CODES.has(fields.error_code)) record.error_code = fields.error_code;
  if (typeof fields.phase === 'string' && ['startup', 'connect', 'query', 'health'].includes(fields.phase)) record.phase = fields.phase;
  return record;
}
export function writeEvent(event: EventName, level: EventLevel = 'INFO', fields: Record<string, unknown> = {}) {
  const line = JSON.stringify(safeEvent(event, level, { ...activeTrace(), ...fields })) + '\n';
  (level === 'ERROR' ? process.stderr : process.stdout).write(line);
}
