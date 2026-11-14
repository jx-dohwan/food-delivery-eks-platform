import type { Server, Socket } from 'socket.io';
import { EventsGateway } from './events.gateway';
import { TokenService } from '../core/jwt/jwt.service';
import { TokenType } from '../core/jwt/jwt.interface';
import { UserRepository } from '../modules/user/repository/user.repository';
import { OrderRepository } from '../modules/order/repository/order.repository';
import { WorkloadLifecycleService } from '../core/health/workload-lifecycle.service';
import { SafeConsoleLogger } from '../core/logger/safe-console.logger';
import { Role } from '../entities/user/user.interface';

it('disconnects Socket.IO clients, clears expiry timers and rejects new connections while draining', async () => {
  jest.useFakeTimers();
  const log = jest
    .spyOn(SafeConsoleLogger.prototype, 'log')
    .mockImplementation(() => {});
  try {
    const lifecycle = new WorkloadLifecycleService();
    const token = {
      verifyAccessToken: jest.fn().mockResolvedValue({
        expired: false,
        payload: {
          type: TokenType.ACCESS,
          sub: '00000000-0000-4000-8000-000000000001',
          exp: Date.now() / 1000 + 3600,
        },
      }),
      isTokenBlacklisted: jest.fn().mockResolvedValue(false),
    };
    const users = {
      findOneByFilters: jest.fn().mockResolvedValue({ role: Role.CLIENT }),
    };
    const gateway = new EventsGateway(
      token as unknown as TokenService,
      users as unknown as UserRepository,
      {} as OrderRepository,
      lifecycle,
    );
    const disconnectSockets = jest.fn();
    gateway.server = { disconnectSockets } as unknown as Server;
    const client = {
      id: 'test',
      handshake: { auth: { accessToken: 'test-token' }, headers: {} },
      disconnect: jest.fn(),
    };
    await gateway.handleConnection(client as unknown as Socket);
    expect(jest.getTimerCount()).toBe(1);
    gateway.onModuleDestroy();
    expect(disconnectSockets).toHaveBeenCalledWith(true);
    expect(jest.getTimerCount()).toBe(0);
    const verificationCount = token.verifyAccessToken.mock.calls.length;
    await gateway.handleConnection(client as unknown as Socket);
    expect(client.disconnect).toHaveBeenCalledWith(true);
    expect(token.verifyAccessToken).toHaveBeenCalledTimes(verificationCount);
  } finally {
    log.mockRestore();
    jest.useRealTimers();
  }
});
