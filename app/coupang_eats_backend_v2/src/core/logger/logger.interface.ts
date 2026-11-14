export interface Log {
  app?: string;
  env?: string;
  data?: unknown;
  stack?: string;
  requestId?: string;
  message?: string;
  logId?: string;
}
