import { Controller, Get, Res } from '@nestjs/common';
import { ApiExcludeController } from '@nestjs/swagger';
import { SkipThrottle } from '@nestjs/throttler';
import type { Response } from 'express';
import { Public } from '../decorator/public.decorator';
import { MetricsService } from './metrics.service';

@ApiExcludeController()
@Public()
@SkipThrottle({ baseline: true, default: true })
@Controller('metrics')
export class MetricsController {
  constructor(private readonly metrics: MetricsService) {}

  @Get()
  async scrape(@Res() response: Response): Promise<void> {
    try {
      const body = await this.metrics.registry.metrics();
      response.setHeader('Content-Type', this.metrics.registry.contentType);
      response.status(200).send(body);
    } catch {
      response.status(503).type('text/plain').send('Metrics unavailable\n');
    }
  }
}
