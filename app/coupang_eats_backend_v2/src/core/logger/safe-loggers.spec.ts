import type { TransformableInfo } from 'logform';
import { SafeTypeOrmLogger } from './safe-typeorm.logger';
import { SafeConsoleLogger } from './safe-console.logger';
import { canonicalFormat } from './logger.module';
import type { DynamicModule, FactoryProvider } from '@nestjs/common';
import winston from 'winston';
import { MoinConfigService } from '../config/config.service';
import { Env } from '../config';
import { WinstonLogger, WINSTON_MODULE_OPTIONS } from 'nest-winston';

describe('SQL and Nest framework log boundaries', () => {
  it('redacts the deployed Winston JSON output before transport delivery', async () => {
    const options: winston.LoggerOptions = {
      format: winston.format.combine(canonicalFormat(), winston.format.json()),
      transports: [new winston.transports.Console()],
    };
    const transport = Array.isArray(options.transports)
      ? options.transports[0]
      : options.transports;
    if (!(transport instanceof winston.transports.Console))
      throw new Error('Expected Console transport');
    const output: string[] = [];
    const delivery = jest
      .spyOn(transport, 'log')
      .mockImplementation((info: TransformableInfo, callback: () => void) => {
        const rendered: unknown = info[Symbol.for('message')];
        if (typeof rendered === 'string') output.push(rendered);
        callback();
      });
    const underlying = winston.createLogger(options);
    try {
      const logger = new WinstonLogger(underlying);
      logger.log({
        message: 'Operation',
        requestId: 'request-123',
        data: {
          password: 'SUPER_SECRET_PASSWORD',
          Cookie: 'COOKIE_SECRET',
          email: 'tester@example.com',
          restaurantId: '123',
        },
      });
      logger.error(new Error('ERROR_SECRET'), undefined, 'Test');
      await new Promise<void>((resolve) => {
        underlying.on('finish', resolve);
        underlying.end();
      });
      const text = output.join('\n');
      expect(text).not.toMatch(
        /SUPER_SECRET_PASSWORD|COOKIE_SECRET|tester@example.com|ERROR_SECRET/,
      );
      expect(text).not.toContain('request-123');
      expect(text).not.toContain('restaurantId');
      expect(text).not.toContain('@example.com');
      expect(text).toContain('application.notice');
      for (const line of output) {
        expect(() => {
          JSON.parse(line);
        }).not.toThrow();
      }
    } finally {
      delivery.mockRestore();
      underlying.close();
    }
  });

  it('never prints SQL parameters/literals or raw DB errors, including CLI migration logs', () => {
    const log = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const warn = jest.spyOn(console, 'warn').mockImplementation();
    const error = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      const logger = new SafeTypeOrmLogger();
      const sql =
        "INSERT INTO user VALUES ('SUPER_SECRET_PASSWORD', 'tester@example.com')";
      const values = ['ARRAY_SECRET', 'COOKIE_SECRET'];
      logger.logQuery(sql, values);
      logger.logQueryError(new Error('SQL_SECRET ' + sql), sql, values);
      logger.logQueryError('RAW_DB_SECRET', sql, values);
      logger.logQuerySlow(100, sql, values);
      logger.log('warn');
      logger.logMigration();
      logger.logSchemaBuild();
      const output = JSON.stringify([
        log.mock.calls,
        warn.mock.calls,
        error.mock.calls,
      ]);
      expect(output).not.toMatch(
        /SUPER_SECRET_PASSWORD|tester@example.com|ARRAY_SECRET|COOKIE_SECRET|SQL_SECRET|RAW_DB_SECRET/,
      );
      expect(output).not.toContain('INSERT');
      expect(output).toContain('database.failed');
      expect(output).not.toContain('parameterCount');
    } finally {
      jest.restoreAllMocks();
    }
  });

  it('protects Nest startup/retry error stack and structured messages before DI exists', () => {
    const stdout = jest
      .spyOn(process.stdout, 'write')
      .mockImplementation(() => true);
    const stderr = jest
      .spyOn(process.stderr, 'write')
      .mockImplementation(() => true);
    try {
      const logger = new SafeConsoleLogger('Test', { colors: false });
      logger.log({
        password: 'SUPER_SECRET_PASSWORD',
        Authorization: 'Bearer VERY_SECRET_JWT',
      });
      logger.error(new Error('ERROR_SECRET tester@example.com'));
      logger.error(
        'Database connection failed',
        'Error: SQL_SECRET\n    at connect (/app/database.ts:10:20)',
        'TypeOrmModule',
      );
      const output = JSON.stringify([stdout.mock.calls, stderr.mock.calls]);
      expect(output).not.toMatch(
        /SUPER_SECRET_PASSWORD|VERY_SECRET_JWT|ERROR_SECRET|SQL_SECRET|tester@example.com/,
      );
      expect(output).not.toContain('database.ts:10:20');
      expect(output).toContain('framework.failed');
    } finally {
      jest.restoreAllMocks();
    }
  });
});
