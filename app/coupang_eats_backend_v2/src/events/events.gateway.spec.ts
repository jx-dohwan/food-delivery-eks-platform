import { SessionUnitStore } from '../../test/helpers/session-unit-store';
import { SessionPolicy } from '../core/jwt/session-policy';
import { Test } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import type { Socket } from 'socket.io';
import { WsException } from '@nestjs/websockets';
import { EventsGateway } from './events.gateway';
import { TokenService } from '../core/jwt/jwt.service';
import { TokenType } from '../core/jwt/jwt.interface';
import { MoinConfigService } from '../core/config/config.service';
import { LoggerService } from '../core/logger/logger.service';
import { CacheServiceKey, CacheKeys } from '../core/cache/cache.interface';
import { UserRepository } from '../modules/user/repository/user.repository';
import { OrderRepository } from '../modules/order/repository/order.repository';
import { User } from '../entities/user/user.entity';
import { OrderEntity } from '../entities/order/order.entity';
import { RestaurantEntity } from '../entities/restaurant/restaurant.entity';
import { Role } from '../entities/user/user.interface';
import { OrderStatus } from '../common/type/common.interface';
import { WorkloadLifecycleService } from '../core/health/workload-lifecycle.service';

const uuid = (n: number) =>
  `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const users = [
  Role.CLIENT,
  Role.CLIENT,
  Role.OWNER,
  Role.OWNER,
  Role.DELIVERY,
  Role.DELIVERY,
].map((role, index) =>
  Object.assign(new User(), { id: uuid(index + 1), role }),
);
const [clientA, clientB, ownerA, ownerB, driverA, driverB] = users;
const jwt = new JwtService();
const secret = 'gateway-security-tests';
const sessions = new SessionUnitStore();
const token = (user: User) =>
  jwt.sign(
    sessions.claims(user.id),
    { secret, expiresIn: '1h' },
  );

describe('WebSocket authentication and order authorization', () => {
  let gateway: EventsGateway;
  let order: OrderEntity;
  const cache = new Map<string, unknown>();
  const repo = {
    findOneWithOmitNotJoinedPropsOrThrow: jest.fn(() => Promise.resolve(order)),
  };
  const userRepo = {
    findOneByFilters: jest.fn((filter: { id: string }) =>
      Promise.resolve(users.find((user) => user.id === filter.id) ?? null),
    ),
  };
  const socket = (
    user?: User,
    accessToken = user ? token(user) : undefined,
  ) => {
    const emit = jest.fn();
    const mock = {
      id: user?.id ?? 'anonymous',
      handshake: { auth: { accessToken }, headers: {} },
      join: jest.fn(() => Promise.resolve()),
      to: jest.fn(() => ({ emit })),
      disconnect: jest.fn(),
    };
    return { client: mock as unknown as Socket, mock, emit };
  };
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      providers: [
        EventsGateway,
        WorkloadLifecycleService,
        TokenService,
        { provide: SessionPolicy, useFactory: () => new SessionPolicy(jwt, sessions as any,
          { accessSecret: secret, refreshSecret: 'gateway-refresh-tests', accessSeconds: 3600, refreshSeconds: 604800 }) },
        { provide: JwtService, useValue: jwt },
        { provide: UserRepository, useValue: userRepo },
        { provide: OrderRepository, useValue: repo },
        {
          provide: CacheServiceKey,
          useValue: {
            get: (key: string) => Promise.resolve(cache.get(key) ?? null),
          },
        },
        { provide: LoggerService, useValue: {} },
        {
          provide: MoinConfigService,
          useValue: { getJwtConfig: () => ({ JWT_ACCESS_SECRET: secret }) },
        },
      ],
    }).compile();
    gateway = module.get(EventsGateway);
  });
  beforeEach(() => {
    jest.clearAllMocks();
    cache.clear();
    sessions.rows.clear();
    order = Object.assign(new OrderEntity(), {
      id: uuid(30),
      customerId: clientB.id,
      restaurant: Object.assign(new RestaurantEntity(), { ownerId: ownerB.id }),
      driverId: driverB.id,
      status: OrderStatus.PickedUp,
    });
  });

  it('disconnects an unauthenticated connection', async () => {
    const { client, mock } = socket();
    await gateway.handleConnection(client);
    expect(mock.disconnect).toHaveBeenCalledWith(true);
    expect(mock.join).not.toHaveBeenCalled();
  });
  it('disconnects on token expiry and cleans up timers', async () => {
    jest.useFakeTimers();
    try {
      const { client, mock } = socket(driverA);
      await gateway.handleConnection(client);
      expect(mock.join).toHaveBeenCalledWith(Role.DELIVERY);
      jest.advanceTimersByTime(3_600_000);
      expect(mock.disconnect).toHaveBeenCalledWith(true);
      gateway.handleDisconnect(client);
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
    }
  });
  it.each(['absent', 'forged', 'expired', 'refresh', 'revoked'])(
    'rejects %s credentials at every event',
    async (kind) => {
      let access: string | undefined = token(clientA);
      if (kind === 'absent') access = undefined;
      if (kind === 'forged')
        access = jwt.sign(
          { sub: clientA.id, type: TokenType.ACCESS },
          { secret: 'wrong' },
        );
      if (kind === 'expired')
        access = jwt.sign(
          { sub: clientA.id, type: TokenType.ACCESS },
          { secret, expiresIn: -1 },
        );
      if (kind === 'refresh')
        access = jwt.sign(
          { sub: clientA.id, type: TokenType.REFRESH },
          { secret },
        );
      if (kind === 'revoked')
        sessions.rows.delete(clientA.id);
      const { client, mock, emit } = socket(undefined, access);
      await expect(
        gateway.handleJoinUserRoom(client, {
          userId: clientA.id,
          role: clientA.role,
        }),
      ).rejects.toThrow(WsException);
      await expect(
        gateway.handleJoinOrderRoom(client, { orderId: order.id }),
      ).rejects.toThrow(WsException);
      await expect(
        gateway.handleDriverLocation(client, {
          orderId: order.id,
          lat: 37,
          lng: 127,
        }),
      ).rejects.toThrow(WsException);
      expect(mock.join).not.toHaveBeenCalled();
      expect(emit).not.toHaveBeenCalled();
    },
  );
  it('denies owner A joining owner B room and derives the room from DB identity', async () => {
    const { client, mock } = socket(ownerA);
    await expect(
      gateway.handleJoinUserRoom(client, {
        userId: ownerB.id,
        role: Role.OWNER,
      }),
    ).rejects.toThrow(WsException);
    expect(mock.join).not.toHaveBeenCalled();
    await gateway.handleJoinUserRoom(client, {
      userId: ownerA.id,
      role: ownerA.role,
    });
    expect(mock.join).toHaveBeenCalledWith(`${Role.OWNER}:${ownerA.id}`);
  });
  it.each([clientA, ownerA, driverA])(
    'denies $role A joining B order room',
    async (user) => {
      const { client, mock } = socket(user);
      await expect(
        gateway.handleJoinOrderRoom(client, { orderId: order.id }),
      ).rejects.toThrow(WsException);
      expect(mock.join).not.toHaveBeenCalled();
    },
  );
  it.each([clientB, ownerB, driverB])(
    'permits the linked $role B order subscriber',
    async (user) => {
      const { client, mock } = socket(user);
      await gateway.handleJoinOrderRoom(client, { orderId: order.id });
      expect(mock.join).toHaveBeenCalledWith(`order:${order.id}`);
    },
  );
  it('denies a pickup-pool driver subscribing before assignment', async () => {
    Object.assign(order, { driverId: null, status: OrderStatus.Cooked });
    const { client, mock } = socket(driverA);
    await expect(
      gateway.handleJoinOrderRoom(client, { orderId: order.id }),
    ).rejects.toThrow(WsException);
    expect(mock.join).not.toHaveBeenCalled();
  });
  it.each([clientB, ownerB, driverA])(
    'denies $role location impersonation',
    async (user) => {
      const { client, emit } = socket(user);
      await expect(
        gateway.handleDriverLocation(client, {
          orderId: order.id,
          lat: 37,
          lng: 127,
        }),
      ).rejects.toThrow(WsException);
      expect(emit).not.toHaveBeenCalled();
    },
  );
  it('allows only the assigned driver location update', async () => {
    const { client, mock, emit } = socket(driverB);
    await gateway.handleDriverLocation(client, {
      orderId: order.id,
      lat: 37,
      lng: 127,
    });
    expect(mock.to).not.toHaveBeenCalled();
    // Real recipient checks and websocket delivery are covered by p1-durable-auth.spec.ts.
  });
});
