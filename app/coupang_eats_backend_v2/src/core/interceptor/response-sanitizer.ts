// Response protection also covers plain objects returned from caches or save().
const isCredentialKey = (key: string): boolean =>
  /password|passwd|^pwd$|token|jwt|authorization|cookie|secret|apikey|credential/.test(
    key.toLowerCase().replace(/[^a-z0-9]/g, ''),
  );

export function sanitizeApiResponse(
  value: unknown,
  allowAccessToken = false,
  ancestors = new WeakSet<object>(),
): unknown {
  if (value === null || typeof value !== 'object') return value;
  if (value instanceof Date) return value;
  if (ancestors.has(value)) return undefined;

  ancestors.add(value);
  try {
    if (Array.isArray(value)) {
      return value.map((item: unknown) =>
        sanitizeApiResponse(item, false, ancestors),
      );
    }
    return Object.fromEntries(
      Object.entries(value)
        .filter(
          ([key]) =>
            !isCredentialKey(key) ||
            (allowAccessToken && key === 'accessToken'),
        )
        .map(([key, child]: [string, unknown]) => [
          key,
          sanitizeApiResponse(child, false, ancestors),
        ]),
    );
  } finally {
    ancestors.delete(value);
  }
}
