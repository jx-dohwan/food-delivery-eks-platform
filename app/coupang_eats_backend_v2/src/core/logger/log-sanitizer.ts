import type { Request } from 'express';

export const REDACTED = '[REDACTED]';
export function isLogRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}
const normalizeKey = (key: string) => key.toLowerCase().replace(/[-_\s]/g, '');
const isSecretKey = (key: string) =>
  /password|passwd|^pwd$|token|jwt|authorization|cookie|secret|apikey|credential/.test(
    normalizeKey(key),
  );
const isPrivateKey = (key: string) =>
  /^(phone|phonenumber|mobile|address|birth|birthday|dateofbirth|ip|clientip)$/.test(
    normalizeKey(key),
  );

export function maskEmail(value: string): string {
  return value.replace(
    /[\w.!#$%&'*+/=?^`{|}~-]+@([\w.-]+\.[a-z]{2,})/gi,
    (email: string, domain: string) =>
      `${email.slice(0, Math.min(2, email.indexOf('@') - 1))}***@${domain}`,
  );
}

/** Only file/line locations survive; error messages and SQL values do not. */
export function safeStackTrace(stack: string | undefined): string {
  return (stack ?? '')
    .split('\n')
    .filter((line) => /^\s+at /.test(line))
    .map(
      (line) => line.match(/([/\w.@ -]+\.(?:[cm]?js|tsx?)):\d+:\d+\)?$/)?.[0],
    )
    .filter((line): line is string => Boolean(line))
    .slice(0, 15)
    .map((line) => `at ${maskEmail(line)}`)
    .join('\n');
}

/** Error messages, SQL, parameters, causes and request/response objects are untrusted. */
export function summarizeLogError(error: unknown): Record<string, unknown> {
  try {
    const result: Record<string, unknown> = {
      errorType: error instanceof Error ? error.constructor.name : 'Error',
    };
    if (error instanceof Error) {
      const stack = safeStackTrace(error.stack);
      if (stack) result.stack = stack;
    }
    if (error && typeof error === 'object') {
      const descriptors = Object.getOwnPropertyDescriptors(error);
      const code: unknown = descriptors.code?.value;
      if (typeof code === 'string' && /^(ER_[A-Z_]+|E[A-Z]+)$/.test(code)) {
        result.code = code;
      }
    }
    return result;
  } catch {
    return { errorType: 'Error' };
  }
}

export function sanitizeLogUrl(value: string): string {
  try {
    const url = new URL(value, 'http://log.invalid');
    const keys = [...new Set(url.searchParams.keys())];
    for (const key of keys) {
      const values = url.searchParams.getAll(key);
      url.searchParams.delete(key);
      for (const item of values) {
        const safe =
          isSecretKey(key) || isPrivateKey(key) || normalizeKey(key) === 'name'
            ? REDACTED
            : sanitizeLogText(item);
        url.searchParams.append(key, safe);
      }
    }
    // Userinfo and fragments may carry credentials; neither is logged.
    const origin = /^https?:\/\//i.test(value) ? url.origin : '';
    const path = sanitizeLogText(decodeURIComponent(url.pathname));
    return `${origin}${path}${url.search}`;
  } catch {
    return '[INVALID_URL]';
  }
}

export function sanitizeLogText(value: string): string {
  // Some legacy callers pass serialized objects instead of structured metadata.
  if (value.trimStart().startsWith('[') || value.trimStart().startsWith('{')) {
    try {
      const parsed: unknown = JSON.parse(value);
      return JSON.stringify(sanitizeForLog(parsed));
    } catch {
      // Ordinary messages still pass through the text rules below.
    }
  }
  if (/\n\s+at /.test(value)) return safeStackTrace(value);
  return maskEmail(value)
    .replace(/\b(?:authorization|cookie|set-cookie)\s*:[^\r\n]*/gi, REDACTED)
    .replace(/\bBearer\s+[^\s"',;]+/gi, `Bearer ${REDACTED}`)
    .replace(/\beyJ[\w-]*(?:\.[\w-]*){2,4}/g, REDACTED)
    .replace(
      /\b((?:[\w-]*(?:password|passwd|token|jwt|secret|api[_-]?key)[\w-]*))\b\s*[=:]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;&]+)/gi,
      `$1=${REDACTED}`,
    )
    .replace(/https?:\/\/[^\s"'<>]+/gi, (url) => sanitizeLogUrl(url));
}

/** A detached log copy: never invokes getters/toJSON and never mutates input. */
export function sanitizeForLog(value: unknown, redactNames = false): unknown {
  const ancestors = new WeakSet<object>();
  const visit = (input: unknown, personal: boolean, depth: number): unknown => {
    if (depth > 8) return '[MAX_DEPTH]';
    if (input === null || input === undefined) return input;
    if (typeof input === 'string') return sanitizeLogText(input);
    if (typeof input === 'bigint') return input.toString();
    if (typeof input !== 'object') {
      return typeof input === 'function' || typeof input === 'symbol'
        ? '[UNSUPPORTED]'
        : input;
    }
    if (input instanceof Error) return summarizeLogError(input);
    if (Buffer.isBuffer(input)) return '[BINARY]';
    if (input instanceof Date) return input.toISOString();
    if (ancestors.has(input)) return '[CIRCULAR]';
    ancestors.add(input);
    try {
      if (Array.isArray(input)) {
        const output = input
          .slice(0, 100)
          .map((item: unknown) => visit(item, personal, depth + 1));
        if (input.length > 100) output.push('[TRUNCATED]');
        return output;
      }
      const descriptors = Object.getOwnPropertyDescriptors(input);
      const keys = Object.keys(descriptors);
      const userObject =
        personal ||
        keys.some((key) =>
          /^(email|password|verified)$/.test(normalizeKey(key)),
        );
      const output: Record<string, unknown> = {};
      for (const key of keys.slice(0, 100)) {
        if (['__proto__', 'constructor', 'prototype'].includes(key)) continue;
        const descriptor = descriptors[key];
        if (!descriptor.enumerable) continue;
        const normalized = normalizeKey(key);
        const childIsUser = /^(users?|profile|customer|owner|driver)$/.test(
          normalized,
        );
        const safeKey = sanitizeLogText(key);
        if (
          isSecretKey(key) ||
          isPrivateKey(key) ||
          /^(fullname|firstname|lastname|nickname)$/.test(normalized) ||
          (userObject && normalized === 'name')
        ) {
          output[safeKey] = REDACTED;
        } else if (!('value' in descriptor)) {
          output[safeKey] = '[GETTER]';
        } else if (
          /^(url|originalurl|path)$/.test(normalized) &&
          typeof descriptor.value === 'string'
        ) {
          output[safeKey] = sanitizeLogUrl(descriptor.value);
        } else {
          output[safeKey] = visit(
            descriptor.value,
            childIsUser || personal,
            depth + 1,
          );
        }
      }
      if (keys.length > 100) output.truncated = true;
      return output;
    } finally {
      ancestors.delete(input);
    }
  };
  try {
    return visit(value, redactNames, 0);
  } catch {
    return '[UNSERIALIZABLE]';
  }
}

export function requestForLog(request: { method?: string; route?: { path?: unknown } }) {
  return { method: request.method, url: typeof request.route?.path === 'string' ? request.route.path : 'unmatched' };
}
