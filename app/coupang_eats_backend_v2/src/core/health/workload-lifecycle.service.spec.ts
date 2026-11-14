import { EventEmitter } from 'node:events';
import type { Server } from 'node:http';
import type { Request, Response } from 'express';
import { Redis } from 'ioredis';
import { CacheService } from '../cache/cache.service';
import { SafeConsoleLogger } from '../logger/safe-console.logger';
import {
  HTTP_DRAIN_TIMEOUT_MS,
  WorkloadLifecycleService,
} from './workload-lifecycle.service';

describe('Bounded workload/resource shutdown', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.spyOn(SafeConsoleLogger.prototype, 'log').mockImplementation(() => {});
    jest
      .spyOn(SafeConsoleLogger.prototype, 'warn')
      .mockImplementation(() => {});
  });
  afterEach(() => {
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  function trackedRequest(lifecycle: WorkloadLifecycleService) {
    const response = new EventEmitter();
    lifecycle.trackRequests(
      { path: '/orders' } as Request,
      response as unknown as Response,
      jest.fn(),
    );
    return response;
  }

  it('waits for an existing response, counting finish/close exactly once', async () => {
    const lifecycle = new WorkloadLifecycleService();
    const response = trackedRequest(lifecycle);
    const closeAllConnections = jest.fn();
    const server = Object.assign(new EventEmitter(), { closeAllConnections });
    lifecycle.bindServer(server as unknown as Server);
    lifecycle.onModuleDestroy();
    let completed = false;
    const closing = lifecycle.beforeApplicationShutdown().then(() => {
      completed = true;
    });
    await Promise.resolve();
    expect(completed).toBe(false);
    expect(lifecycle.isDraining).toBe(true);
    response.emit('finish');
    response.emit('close');
    await closing;
    expect(completed).toBe(true);
    expect(closeAllConnections).not.toHaveBeenCalled();
    server.emit('close');
    expect(jest.getTimerCount()).toBe(0);
  });

  it('bounds a stuck request without waiting forever', async () => {
    const lifecycle = new WorkloadLifecycleService();
    trackedRequest(lifecycle);
    const closeAllConnections = jest.fn();
    const server = Object.assign(new EventEmitter(), { closeAllConnections });
    lifecycle.bindServer(server as unknown as Server);
    const closing = lifecycle.beforeApplicationShutdown();
    await jest.advanceTimersByTimeAsync(HTTP_DRAIN_TIMEOUT_MS);
    await closing;
    expect(closeAllConnections).toHaveBeenCalledTimes(1);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('keeps a deadline through native server.close without initial requests', async () => {
    const lifecycle = new WorkloadLifecycleService();
    const closeAllConnections = jest.fn();
    const server = Object.assign(new EventEmitter(), { closeAllConnections });
    lifecycle.bindServer(server as unknown as Server);
    await lifecycle.beforeApplicationShutdown();
    await jest.advanceTimersByTimeAsync(HTTP_DRAIN_TIMEOUT_MS);
    expect(closeAllConnections).toHaveBeenCalledTimes(1);
    lifecycle.onApplicationShutdown();
    expect(jest.getTimerCount()).toBe(0);
  });

  it('marks drain once and logs safe event names only', () => {
    const log = jest.spyOn(SafeConsoleLogger.prototype, 'log');
    const lifecycle = new WorkloadLifecycleService();
    lifecycle.beginDrain();
    lifecycle.onModuleDestroy();
    expect(log).toHaveBeenCalledTimes(1);
    expect(log).toHaveBeenCalledWith({
      event: 'shutdown_start',
    });
  });

  it('quits Redis after serving traffic and disconnects its socket', async () => {
    const redis = {
      status: 'ready',
      quit: jest.fn().mockResolvedValue('OK'),
      disconnect: jest.fn(),
    };
    await new CacheService(redis as unknown as Redis).onApplicationShutdown();
    expect(redis.quit).toHaveBeenCalledTimes(1);
    expect(redis.disconnect).toHaveBeenCalledWith(false);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('forces Redis disconnect after the bounded quit deadline', async () => {
    const redis = {
      status: 'ready',
      quit: jest.fn(() => new Promise(() => {})),
      disconnect: jest.fn(),
    };
    const closing = new CacheService(
      redis as unknown as Redis,
    ).onApplicationShutdown();
    await jest.advanceTimersByTimeAsync(2_000);
    await closing;
    expect(redis.disconnect).toHaveBeenCalledWith(false);
    expect(jest.getTimerCount()).toBe(0);
  });

  it('does not queue QUIT while Redis is reconnecting', async () => {
    const redis = {
      status: 'reconnecting',
      quit: jest.fn(),
      disconnect: jest.fn(),
    };
    await new CacheService(redis as unknown as Redis).onApplicationShutdown();
    expect(redis.quit).not.toHaveBeenCalled();
    expect(redis.disconnect).toHaveBeenCalledWith(false);
  });
});
