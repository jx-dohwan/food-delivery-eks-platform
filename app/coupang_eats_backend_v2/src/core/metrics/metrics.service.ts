import { telemetryState } from '../tracing/telemetry-state';
import { Injectable } from '@nestjs/common';
import type { Request, RequestHandler } from 'express';
import {
  collectDefaultMetrics,
  Counter,
  Histogram,
  Gauge,
  Registry,
} from 'prom-client';

const METHODS = new Set([
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'OPTIONS',
]);

@Injectable()
export class MetricsService {
  readonly registry = new Registry();
  private readonly requests = new Counter({
    name: 'food_delivery_http_requests_total',
    help: 'Completed HTTP responses, excluding health and metrics.',
    labelNames: ['method', 'route', 'status_code'] as const,
    registers: [this.registry],
  });
  private readonly duration = new Histogram({
    name: 'food_delivery_http_request_duration_seconds',
    help: 'HTTP response duration in seconds.',
    labelNames: ['method', 'route', 'status_code'] as const,
    buckets: [0.005, 0.025, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
    registers: [this.registry],
  });

  constructor() {
    collectDefaultMetrics({ register: this.registry });
    new Gauge({ name: 'food_delivery_tracing_enabled', help: 'Configured trace export enabled.',
      registers: [this.registry], collect() { this.set(telemetryState.enabled ? 1 : 0); } });
    new Gauge({ name: 'food_delivery_tracing_active', help: 'SDK started; not proof of export delivery.',
      registers: [this.registry], collect() { this.set(telemetryState.active ? 1 : 0); } });
    new Counter({ name: 'food_delivery_telemetry_failures_total', help: 'Safe telemetry failures since process start.',
      labelNames: ['stage'], registers: [this.registry], collect() {
        this.reset();
        for (const stage of ['sdk_start', 'export'] as const) this.inc({ stage }, telemetryState.failures[stage]);
      } });
  }

  // Called only after routing/guards have completed. Never fall back to raw URL.
  record(request: Request, statusCode: number, seconds: number): void {
    const route: unknown = request.route;
    const template =
      typeof route === 'object' &&
      route !== null &&
      'path' in route &&
      typeof route.path === 'string'
        ? route.path
        : 'unmatched';
    const labels = {
      method: METHODS.has(request.method) ? request.method : 'OTHER',
      route: template,
      status_code: String(statusCode),
    };
    this.requests.inc(labels);
    this.duration.observe(labels, seconds);
  }

  readonly trackRequests: RequestHandler = (request, response, next) => {
    // Compare paths only to suppress telemetry endpoints; never export them.
    if (/^\/(?:health(?:\/.*)?|metrics\/?)$/i.test(request.path)) {
      next();
      return;
    }
    const started = process.hrtime.bigint();
    response.once('finish', () => {
      try {
        this.record(
          request,
          response.statusCode,
          Number(process.hrtime.bigint() - started) / 1e9,
        );
      } catch {
        // Metrics are best effort; never log request/error data or fail traffic.
      }
    });
    next();
  };
}
