import { Global, Module } from '@nestjs/common';
import { CacheModule } from '../cache/cache.module';
import { HealthController } from './health.controller';
import { HealthService } from './health.service';
import { WorkloadLifecycleService } from './workload-lifecycle.service';

@Global()
@Module({
  imports: [CacheModule],
  controllers: [HealthController],
  providers: [HealthService, WorkloadLifecycleService],
  exports: [WorkloadLifecycleService],
})
export class HealthModule {}
