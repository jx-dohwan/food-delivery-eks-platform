import { ConsoleLogger, LogLevel } from '@nestjs/common';
import { errorFields, writeEvent } from './safe-event';
export class SafeConsoleLogger extends ConsoleLogger {
  protected printMessages(messages: unknown[], _context?: string, level?: LogLevel): void {
    const error = messages.find((message) => message instanceof Error);
    const severity = level === 'error' || level === 'fatal' ? 'ERROR' : level === 'warn' ? 'WARN' : level === 'debug' || level === 'verbose' ? 'DEBUG' : 'INFO';
    if (severity === 'DEBUG') return;
    writeEvent(severity === 'ERROR' ? 'framework.failed' : 'framework.notice', severity, error ? errorFields(error) : {});
  }
  protected printStackTrace(_stack: string): void {}
}
