import './instrumentation';
import { writeEvent, errorFields } from './core/logger/safe-event';
import { NestFactory } from '@nestjs/core';
import type { INestApplication } from '@nestjs/common';
import type { Server } from 'node:http';
import { AppModule } from './app.module';
import { setNestApp } from './setNestApp';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import {
  initializeTransactionalContext,
  StorageDriver,
} from 'typeorm-transactional';
import cookieParser from 'cookie-parser';
import { SafeConsoleLogger } from './core/logger/safe-console.logger';
import { configureWorkloadLifecycle } from './core/health/configure-workload-lifecycle';
import { configureMetrics } from './core/metrics/configure-metrics';

initializeTransactionalContext({ storageDriver: StorageDriver.AUTO });

async function bootstrap() {
  const app = await NestFactory.create<INestApplication<Server>>(AppModule, {
    logger: new SafeConsoleLogger(),
  });
  configureMetrics(app);
  configureWorkloadLifecycle(app);

  //  2. 쿠키 파서 등록 (반드시 setNestApp이나 다른 설정보다 위에 있는 것이 좋습니다)
  app.use(cookieParser());

  // 공통 설정 작용
  setNestApp(app);

  // Swagger 설정
  const config = new DocumentBuilder()
    .setTitle('Coupang Eats API')
    .setDescription('Coupang Eats 클론 코딩 API 문서입니다.')
    .setVersion('1.0')
    .addBearerAuth(
      {
        type: 'http',
        scheme: 'bearer',
        bearerFormat: 'JWT',
        name: 'JWT',
        description: 'Enter Access Token',
        in: 'header',
      },
      'access-token',
    )
    //  3. 스웨거에 쿠키 인증 방식 추가 (프론트엔드 노출용)
    .addCookieAuth('refreshToken', {
      type: 'apiKey',
      in: 'cookie',
      name: 'refreshToken',
      description: 'Refresh Token stored in cookie',
    })
    .build();

  const document = SwaggerModule.createDocument(app, config);

  SwaggerModule.setup('api-docs', app, document, {
    swaggerOptions: {
      persistAuthorization: true,
    },
  });

  await app.listen(process.env.PORT ?? 3000);
  writeEvent('application.started');
}
void bootstrap().catch((error: unknown) => {
  writeEvent('application.failed', 'ERROR', errorFields(error));
  process.exitCode = 1;
});
