import { ClsModule } from '../cls/cls.module';
import { BadRequestException, Controller, Get, Post, Module, NestModule, MiddlewareConsumer } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Writable } from 'node:stream';
import { EventEmitter } from 'node:events';
import request from 'supertest';
import winston from 'winston';
import { WinstonLogger } from 'nest-winston';
import { LoggerService } from './logger.service';
import { canonicalFormat } from './logger.module';
import { safeEvent, errorFields } from './safe-event';
import { SafeConsoleLogger } from './safe-console.logger';
import { SafeTypeOrmLogger } from './safe-typeorm.logger';
import { ErrorFilter } from '../filter/error.filter';
import { RequestLoggerMiddleware } from '../middleware/requestLogger.middleware';
import { RequestContextService } from '../cls/cls.service';
import { MoinConfigService } from '../config/config.service';

const SYNTHETIC = 'SYNTHETIC_PRIVATE_VALUE_8172';
@Controller('auth')
class TestController {
  @Post('sign-in') invalid() { throw new BadRequestException({ message: [SYNTHETIC] }); }
  @Get('verify-email') verify() { return { ok: true }; }
  @Get('failure') fail() { throw Object.assign(new Error(SYNTHETIC), { query: SYNTHETIC, code: 'ER_ACCESS_DENIED_ERROR' }); }
}
describe('central JSON privacy and real HTTP boundary', () => {
  let lines: string[];
  let logger: LoggerService;
  beforeEach(() => {
    lines = [];
    const stream = new Writable({ write(chunk, _encoding, next) { lines.push(chunk.toString()); next(); } });
    const underlying = winston.createLogger({ format: winston.format.combine(canonicalFormat(), winston.format.json()), transports: [new winston.transports.Stream({ stream })] });
    logger = new LoggerService(new WinstonLogger(underlying), {}, {} as MoinConfigService);
  });
  it('writes one flat canonical JSON record and drops unknown free text at Winston boundary', () => {
    logger.info(SYNTHETIC, { body: SYNTHETIC, email: SYNTHETIC }, SYNTHETIC);
    logger.event('database.failed', 'ERROR', { ...errorFields(Object.assign(new Error(SYNTHETIC), { code: 'ER_ACCESS_DENIED_ERROR' })), password: SYNTHETIC });
    const records = lines.map((line) => JSON.parse(line));
    expect(records).toHaveLength(2);
    expect(records[1]).toMatchObject({ level: 'ERROR', event: 'database.failed', error_code: 'ER_ACCESS_DENIED_ERROR', service: 'was' });
    expect(records[1].timestamp).toMatch(/Z$/);
    expect(lines.join('')).not.toContain(SYNTHETIC);
    expect(records[1].data).toBeUndefined();
    expect(records[1].trace_id).toBeUndefined();
  });
  it('drops invalid identifiers, unexpected errors, raw exception and unknown keys', () => {
    const row = safeEvent('application.failed', 'ERROR', { request_id: SYNTHETIC, trace_id: SYNTHETIC, body: SYNTHETIC, message: SYNTHETIC, ...errorFields({ name: SYNTHETIC, code: SYNTHETIC }) });
    expect(row).toMatchObject({ error_type: 'OtherError' });
    expect(JSON.stringify(row)).not.toContain(SYNTHETIC);
  });
  it('never emits raw SQL, library exception, multiline stack or Nest free text', () => {
    const out = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);
    const err = jest.spyOn(process.stderr, 'write').mockImplementation(() => true);
    try {
      new SafeConsoleLogger().error(new Error(SYNTHETIC), `Error: ${SYNTHETIC}\n at ${SYNTHETIC}`);
      const db = new SafeTypeOrmLogger();
      db.logQuery(`SELECT '${SYNTHETIC}'`, [SYNTHETIC]);
      db.logQueryError(new Error(SYNTHETIC), SYNTHETIC, [SYNTHETIC]);
      db.logQuerySlow(800, SYNTHETIC);
      const records = [...out.mock.calls, ...err.mock.calls].map((args) => JSON.parse(String(args[0])));
      expect(records.length).toBeGreaterThanOrEqual(3);
      expect(JSON.stringify(records)).not.toContain(SYNTHETIC);
      expect(records.some((r) => r.event === 'database.failed')).toBe(true);
    } finally { out.mockRestore(); err.mockRestore(); }
  });
  it('keeps 4xx response behavior while never logging body/query/header/validation text; 5xx response safe', async () => {
    @Module({ imports: [ClsModule], controllers: [TestController], providers: [RequestLoggerMiddleware, { provide: LoggerService, useValue: logger }] })
    class RealContextTestModule implements NestModule {
      configure(consumer: MiddlewareConsumer) { consumer.apply(RequestLoggerMiddleware).forRoutes(TestController); }
    }
    const module = await Test.createTestingModule({ imports: [RealContextTestModule] }).compile();
    const app = module.createNestApplication({ logger: false });
    app.useGlobalFilters(new ErrorFilter(logger, {} as MoinConfigService));
    await app.init();
    await app.listen(0, "127.0.0.1");
    try {
      await request(app.getHttpServer()).post('/auth/sign-in?token='+SYNTHETIC).set('Authorization', 'Bearer '+SYNTHETIC).set('Cookie', 'session='+SYNTHETIC).send({ password: SYNTHETIC, email: 'synthetic@example.invalid' }).expect(400);
      await request(app.getHttpServer()).get('/auth/verify-email?token='+SYNTHETIC).expect(200);
      const response = await request(app.getHttpServer()).get('/auth/failure?token='+SYNTHETIC).expect(500);
      expect(JSON.stringify(response.body)).not.toContain(SYNTHETIC);
      const rows = lines.map((line) => JSON.parse(line));
      expect(rows.filter((row) => row.event === 'http.exception' || row.event.startsWith('auth.')).every((row) => /^[a-f0-9-]{36}$/.test(row.request_id))).toBe(true);
      expect(rows.some((row) => row.event === 'auth.failed' && row.status_code === 400)).toBe(true);
      expect(rows.some((row) => row.event === 'auth.succeeded' && row.http_route === '/auth/verify-email')).toBe(true);
      expect(lines.join('')).not.toMatch(new RegExp(SYNTHETIC+'|synthetic@example.invalid|Authorization|Cookie'));
    } finally { await app.close(); }
  });
  it('logs all failed requests and samples ordinary successes without logging start records', () => {
    const random = jest.spyOn(Math, 'random').mockReturnValue(0.9);
    try {
      const res = Object.assign(new EventEmitter(), { setHeader: jest.fn(), statusCode: 200 });
      const req = { method: 'GET', route: { path: '/users/:id' }, headers: {}, originalUrl: '/users/'+SYNTHETIC };
      new RequestLoggerMiddleware(logger, { getRequestId: () => '' } as RequestContextService).use(req as never, res as never, () => {});
      res.emit('finish'); expect(lines).toHaveLength(0);
      res.statusCode = 403; res.emit('finish');
      expect(JSON.parse(lines[0])).toMatchObject({ event: 'access.denied', http_route: '/users/:id' });
      expect(lines.join('')).not.toContain(SYNTHETIC);
    } finally { random.mockRestore(); }
  });
});
