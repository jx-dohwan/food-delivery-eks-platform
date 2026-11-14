import {
  Controller,
  ForbiddenException,
  Get,
  HttpCode,
  Post,
  Req,
  Res,
} from '@nestjs/common';
import { ApiExcludeController } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import type { Request, Response } from 'express';
import { Public } from '../decorator/public.decorator';
import { HealthService } from './health.service';
import { WorkloadLifecycleService } from './workload-lifecycle.service';

@ApiExcludeController()
@Public()
@SkipThrottle({ baseline: true, default: true })
@Controller('health')
export class HealthController {
  constructor(
    private readonly health: HealthService,
    private readonly lifecycle: WorkloadLifecycleService,
  ) {}

  @Get('live')
  live(): { status: string } {
    return { status: 'ok' };
  }

  @Get('startup')
  startup(@Res() response: Response): void {
    response
      .status(this.lifecycle.hasStarted ? 200 : 503)
      .json({ status: this.lifecycle.hasStarted ? 'ok' : 'unavailable' });
  }

  @Get('ready')
  async ready(@Res() response: Response): Promise<void> {
    const healthy = await this.health.isReady();
    response.status(healthy ? 200 : 503).json({
      status: healthy ? 'ok' : 'unavailable',
    });
  }

  @Post('drain')
  @HttpCode(200)
  drain(@Req() request: Request): { status: string } {
    // Never trust req.ip / forwarded headers for this administrative action.
    if (
      !['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(
        request.socket.remoteAddress ?? '',
      )
    ) {
      throw new ForbiddenException('Not allowed');
    }
    this.lifecycle.beginDrain();
    return { status: 'draining' };
  }
}
