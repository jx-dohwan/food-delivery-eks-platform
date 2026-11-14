import { ShutdownSignal, type INestApplication } from '@nestjs/common';
import type { Server } from 'node:http';
import { WorkloadLifecycleService } from './workload-lifecycle.service';

export function configureWorkloadLifecycle(
  app: INestApplication<Server>,
): void {
  const lifecycle = app.get(WorkloadLifecycleService);
  lifecycle.bindServer(app.getHttpServer());
  app.use(lifecycle.trackRequests);
  app.enableShutdownHooks([ShutdownSignal.SIGTERM, ShutdownSignal.SIGINT]);
}
