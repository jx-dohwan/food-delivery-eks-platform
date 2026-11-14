import { Controller, Get } from '@nestjs/common';
import { Public } from './core/decorator/public.decorator';
import { ApiExcludeEndpoint, ApiOperation, ApiTags } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';

@ApiTags('Health')
@Controller()
@SkipThrottle({ baseline: true, default: true })
export class AppController {
  /** Legacy process health. Probes use /health/*; ALB checks Web /readyz. */
  @Public()
  @Get('health')
  @ApiOperation({ summary: '호환용 process 헬스체크' })
  health(): { status: string } {
    return { status: 'ok' };
  }

  /** 하위 호환 (로컬·구 헬스체크). */
  @Public()
  @Get()
  @ApiExcludeEndpoint()
  root(): string {
    return 'OK';
  }
}
