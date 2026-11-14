import { Inject, Injectable, Scope } from '@nestjs/common';
import { INQUIRER } from '@nestjs/core';
import { WINSTON_MODULE_NEST_PROVIDER, WinstonLogger } from 'nest-winston';
import { MoinConfigService } from '../config/config.service';
import { activeTrace, errorFields, EventLevel, EventName, safeEvent } from './safe-event';
@Injectable({ scope: Scope.TRANSIENT })
export class LoggerService {
  constructor(@Inject(WINSTON_MODULE_NEST_PROVIDER) private readonly logger: WinstonLogger,
    @Inject(INQUIRER) private readonly caller: object,
    private readonly configService: MoinConfigService) {}
  setContext(_context: string) {} // Legacy free-text context is intentionally discarded.
  event(event: EventName, level: EventLevel = 'INFO', fields: Record<string, unknown> = {}) {
    const record = { ...safeEvent(event, level, { ...activeTrace(), ...fields }), level: level.toLowerCase() };
    if (level === 'ERROR') this.logger.error(record);
    else if (level === 'WARN') this.logger.warn(record);
    else if (level === 'DEBUG') this.logger.debug?.(record);
    else this.logger.log(record);
  }
  private legacy(level: EventLevel, value: unknown) {
    this.event(level === 'ERROR' ? 'application.failed' : 'application.notice', level,
      value instanceof Error ? errorFields(value) : {});
  }
  verbose(_context: string, value: object | string, _message?: string) { this.legacy('DEBUG', value); }
  debug(_context: string, value: object | string, _message?: string) { this.legacy('DEBUG', value); }
  info(_context: string, value: object | string, _message?: string) { this.legacy('INFO', value); }
  warn(_context: string, value: object | string, _message?: string) { this.legacy('WARN', value); }
  error(_context: string, value: object | string, _message?: string) { this.legacy('ERROR', value); }
}
