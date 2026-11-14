import { Global, Module } from '@nestjs/common';
import { WinstonModule } from 'nest-winston';
import winston from 'winston';
import { LoggerService } from './logger.service';
import { EventLevel, EventName, safeEvent } from './safe-event';
export const canonicalFormat = winston.format((info) => {
  const candidate = (typeof info.message === 'object' && info.message !== null ? info.message : info) as Record<string, unknown>;
  const levels: Record<string, EventLevel> = { error: 'ERROR', warn: 'WARN', debug: 'DEBUG', verbose: 'DEBUG' };
  const record = safeEvent(candidate.event as EventName, levels[info.level] ?? 'INFO', candidate);
  return { ...record, level: record.level as string, message: record.message, [Symbol.for('level')]: info.level };
});
@Global()
@Module({
  imports: [WinstonModule.forRoot({
    format: winston.format.combine(canonicalFormat(), winston.format.json()),
    transports: [new winston.transports.Console({ level: 'info' })],
  })],
  providers: [LoggerService], exports: [LoggerService],
})
export class LoggerModule {}
