import type { INestApplication } from '@nestjs/common';
import { MetricsService } from './metrics.service';

export function configureMetrics(app: INestApplication): void {
  app.use(app.get(MetricsService).trackRequests);
}
