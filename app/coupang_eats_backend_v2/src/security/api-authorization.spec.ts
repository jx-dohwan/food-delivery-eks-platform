import { SessionUnitStore } from '../../test/helpers/session-unit-store';
import { SessionPolicy } from '../core/jwt/session-policy';
import { INestApplication, NotFoundException } from '@nestjs/common';
import { APP_FILTER, APP_GUARD, APP_INTERCEPTOR } from '@nestjs/core';
import { Test } from '@nestjs/testing';
import { JwtService } from '@nestjs/jwt';
import request from 'supertest';
import type { Server } from 'http';
import { In, IsNull } from 'typeorm';
import { setNestApp } from '../setNestApp';
import { User } from '../entities/user/user.entity';
import { Role } from '../entities/user/user.interface';
import { OrderEntity } from '../entities/order/order.entity';
import { RestaurantEntity } from '../entities/restaurant/restaurant.entity';
import { DishEntity } from '../entities/dish/dish.entity';
import { ReviewEntity } from '../entities/review/review.entity';
import { PaymentEntity } from '../entities/payment/payment.entity';
import { CategoryEntity } from '../entities/category/category.entity';
import { OrderStatus } from '../common/type/common.interface';
import { AuthController } from '../modules/auth/auth.controller';
import { AuthService } from '../modules/auth/auth.service';
import { AuthTxService } from '../modules/auth/auth.tx.service';
import { UserController } from '../modules/user/user.controller';
import { UserService } from '../modules/user/user.service';
import { UserRepository } from '../modules/user/repository/user.repository';
import { OrderController } from '../modules/order/order.controller';
import { OrderService } from '../modules/order/order.service';
import { OrderRepository } from '../modules/order/repository/order.repository';
import { OrderItemRepository } from '../modules/order/repository/order-item.repository';
import { RestaurantController } from '../modules/restaurant/restaurant.controller';
import { RestaurantService } from '../modules/restaurant/restaurant.service';
import { RestaurantRepository } from '../modules/restaurant/repository/restaurant.repository';
import { DishController } from '../modules/dish/dish.controller';
import { DishService } from '../modules/dish/dish.service';
import { DishRepository } from '../modules/dish/repository/dish.repository';
import { ReviewController } from '../modules/review/review.controller';
import { ReviewService } from '../modules/review/review.service';
import { ReviewRepository } from '../modules/review/repository/review.repository';
import { PaymentController } from '../modules/payment/payment.controller';
import { PaymentService } from '../modules/payment/payment.service';
import { PaymentRepository } from '../modules/payment/repository/payment.repository';
import { CategoryController } from '../modules/category/category.controller';
import { CategoryService } from '../modules/category/category.service';
import { CategoryRepository } from '../modules/category/repository/category.repository';
import { AccessTokenGuard } from '../core/guard/accessToken.guard';
import { JwtBlacklistGuard } from '../core/guard/jwtBlacklist.guard';
import { AccessTokenStrategy } from '../core/jwt/accessToken.strategy';
import { RefreshTokenStrategy } from '../core/jwt/refreshToken.strategy';
import { TokenService } from '../core/jwt/jwt.service';
import { TokenType } from '../core/jwt/jwt.interface';
import { ApiResponseInterceptor } from '../core/interceptor/apiResponse.interceptor';
import { ErrorFilter } from '../core/filter/error.filter';
import { MoinConfigService } from '../core/config/config.service';
import { LoggerService } from '../core/logger/logger.service';
import { RequestContextService } from '../core/cls/cls.service';
import { CacheServiceKey, CacheKeys } from '../core/cache/cache.interface';
import { HASH_SERVICE } from '../core/hash/hash.interface';
import { NOTIFICATION_SERVICE } from '../core/notification/notification.interface';
import { EventsGateway } from '../events/events.gateway';
import { getOptionsToken, getStorageToken } from '@nestjs/throttler';
import {
  IpRateLimitGuard,
  ApiRateLimitGuard,
} from '../core/rate-limit/rate-limit.guard';
import { rateLimitOptions } from '../core/rate-limit/rate-limit.policy';
import { MemoryRateLimitStorage } from '../core/rate-limit/rate-limit.storage';

// Database transactions are isolated here; the real controllers, guards,
// Passport strategies, services, validation and response filter are exercised.
jest.mock('typeorm-transactional', () => ({
  Transactional:
    () => (_target: object, _key: string, descriptor: PropertyDescriptor) =>
      descriptor,
  runOnTransactionCommit: (callback: () => void) => callback(),
}));

const uuid = (n: number) =>
  `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const makeUser = (n: number, role: Role) =>
  Object.assign(new User(), {
    id: uuid(n),
    role,
    email: `user${n}@example.com`,
    name: `User ${n}`,
    verified: true,
    password: 'PASSWORD_HASH_MUST_NOT_LEAK',
  });
const clientA = makeUser(1, Role.CLIENT);
const clientB = makeUser(2, Role.CLIENT);
const ownerA = makeUser(3, Role.OWNER);
const ownerB = makeUser(4, Role.OWNER);
const driverA = makeUser(5, Role.DELIVERY);
const driverB = makeUser(6, Role.DELIVERY);
const users = [clientA, clientB, ownerA, ownerB, driverA, driverB];
const jwt = new JwtService();
const secret = 'authorization-tests-access-secret';
const refreshSecret = 'authorization-tests-refresh-secret';
const sessions = new SessionUnitStore();
const token = (user: User) =>
  jwt.sign(
    sessions.claims(user.id),
    { secret, expiresIn: '1h' },
  );
const requireEntity = <T>(entity: T | undefined): T => {
  if (!entity) throw new NotFoundException('Not found');
  return entity;
};

describe('HTTP authorization and response security (isolated persistence)', () => {
  let app: INestApplication;
  let server: Server;
  let restaurants: RestaurantEntity[];
  let dishes: DishEntity[];
  let orders: OrderEntity[];
  let reviews: ReviewEntity[];
  const cached = new Map<string, unknown>();
  let rateStore = new MemoryRateLimitStorage();
  const userRepo = {
    findOneByFilters: jest.fn((filter: { id?: string; email?: string }) =>
      Promise.resolve(
        users.find((user) =>
          filter.id ? user.id === filter.id : user.email === filter.email,
        ) ?? null,
      ),
    ),
    findByIdOrThrow: jest.fn((id: string) =>
      Promise.resolve(requireEntity(users.find((user) => user.id === id))),
    ),
    save: jest.fn((user: User) => Promise.resolve(user)),
  };
  const orderRepo = {
    findOneWithOmitNotJoinedPropsOrThrow: jest.fn((filter: { id: string }) =>
      Promise.resolve(
        requireEntity(orders.find((order) => order.id === filter.id)),
      ),
    ),
    findForStatusUpdate: jest.fn((id: string) =>
      Promise.resolve(requireEntity(orders.find((order) => order.id === id))),
    ),
    findByIdOrThrow: jest.fn((id: string) =>
      Promise.resolve(requireEntity(orders.find((order) => order.id === id))),
    ),
    findManyWithOmitNotJoinedProps: jest.fn<
      Promise<OrderEntity[]>,
      unknown[]
    >(),
    find: jest.fn<Promise<OrderEntity[]>, unknown[]>(),
    save: jest.fn((order: OrderEntity) => Promise.resolve(order)),
  };
  const restaurantRepo = {
    findByIdOrThrow: jest.fn((id: string) =>
      Promise.resolve(requireEntity(restaurants.find((r) => r.id === id))),
    ),
    findMany: jest.fn((filter: { ownerId: string }) =>
      Promise.resolve(restaurants.filter((r) => r.ownerId === filter.ownerId)),
    ),
    findOneWithOmitNotJoinedPropsOrThrow: jest.fn((filter: { id: string }) =>
      Promise.resolve(
        requireEntity(restaurants.find((r) => r.id === filter.id)),
      ),
    ),
    paginate: jest.fn<Promise<unknown>, unknown[]>(),
    create: jest.fn((r: RestaurantEntity) => r),
    save: jest.fn((r: RestaurantEntity) => Promise.resolve(r)),
  };
  const dishRepo = {
    findOneWithOmitNotJoinedPropsOrThrow: jest.fn(
      (filter: { id: string; restaurantId?: string }) =>
        Promise.resolve(
          requireEntity(
            dishes.find(
              (d) =>
                d.id === filter.id &&
                (!filter.restaurantId ||
                  d.restaurantId === filter.restaurantId),
            ),
          ),
        ),
    ),
    findManyWithOmitNotJoinedProps: jest.fn<Promise<DishEntity[]>, unknown[]>(),
    create: jest.fn((d: DishEntity) => d),
    save: jest.fn((d: DishEntity) => Promise.resolve(d)),
    softDelete: jest.fn(() => Promise.resolve()),
  };
  const reviewRepo = {
    findOneWithOmitNotJoinedPropsOrThrow: jest.fn((filter: { id: string }) =>
      Promise.resolve(requireEntity(reviews.find((r) => r.id === filter.id))),
    ),
    findOneByFilters: jest.fn<Promise<ReviewEntity | null>, unknown[]>(),
    create: jest.fn((r: ReviewEntity) => r),
    save: jest.fn((r: ReviewEntity) => Promise.resolve(r)),
    softDelete: jest.fn(() => Promise.resolve()),
  };
  const paymentRepo = {
    findOneByFilters: jest.fn<Promise<PaymentEntity | null>, unknown[]>(),
    save: jest.fn((p: PaymentEntity) => Promise.resolve(p)),
  };
  const categoryRepo = {
    findOneByFilters: jest.fn<Promise<CategoryEntity | null>, unknown[]>(),
    findByIdOrThrow: jest.fn<Promise<CategoryEntity>, unknown[]>(),
    findAll: jest.fn(() => Promise.resolve([])),
    save: jest.fn((c: CategoryEntity) => Promise.resolve(c)),
  };
  const createUser = jest.fn(() => Promise.resolve());

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [
        AuthController,
        UserController,
        OrderController,
        RestaurantController,
        DishController,
        ReviewController,
        PaymentController,
        CategoryController,
      ],
      providers: [
        AuthService,
        UserService,
        OrderService,
        RestaurantService,
        DishService,
        ReviewService,
        PaymentService,
        CategoryService,
        AccessTokenStrategy,
        RefreshTokenStrategy,
        TokenService,
        { provide: SessionPolicy, useFactory: () => new SessionPolicy(jwt, sessions as any,
          { accessSecret: secret, refreshSecret: refreshSecret, accessSeconds: 3600, refreshSeconds: 604800 }) },
        { provide: JwtService, useValue: jwt },
        { provide: UserRepository, useValue: userRepo },
        { provide: OrderRepository, useValue: orderRepo },
        { provide: RestaurantRepository, useValue: restaurantRepo },
        { provide: DishRepository, useValue: dishRepo },
        { provide: ReviewRepository, useValue: reviewRepo },
        { provide: PaymentRepository, useValue: paymentRepo },
        { provide: CategoryRepository, useValue: categoryRepo },
        {
          provide: OrderItemRepository,
          useValue: { create: (item: unknown) => item },
        },
        { provide: AuthTxService, useValue: { createUserOrThrow: createUser } },
        {
          provide: EventsGateway,
          useValue: {
            emitAuthorizedRoom: jest.fn(async () => undefined),
            server: {
              to: jest.fn().mockReturnThis(),
              emit: jest.fn(),
            },
          },
        },
        {
          provide: CacheServiceKey,
          useValue: {
            get: (key: string) => Promise.resolve(cached.get(key) ?? null),
            set: (key: string, value: unknown) => {
              cached.set(key, value);
              return Promise.resolve();
            },
            del: (key: string) => {
              cached.delete(key);
              return Promise.resolve();
            },
          },
        },
        {
          provide: HASH_SERVICE,
          useValue: {
            hash: (value: string) => Promise.resolve(`HASHED_${value}`),
            compare: (value: string) =>
              Promise.resolve(value === 'ValidPass123!'),
          },
        },
        {
          provide: NOTIFICATION_SERVICE,
          useValue: { sendWelcomeNotification: jest.fn() },
        },
        {
          provide: LoggerService,
          useValue: { event: jest.fn(), info: jest.fn(), error: jest.fn(), warn: jest.fn() },
        },
        {
          provide: RequestContextService,
          useValue: { getRequestId: () => 'security-test' },
        },
        {
          provide: MoinConfigService,
          useValue: {
            getJwtConfig: () => ({
              JWT_ACCESS_SECRET: secret,
              JWT_REFRESH_SECRET: refreshSecret,
              JWT_ACCESS_EXPIRATION: '1h',
              JWT_REFRESH_EXPIRATION: '7d',
            }),
          },
        },
        { provide: getOptionsToken(), useValue: rateLimitOptions() },
        {
          provide: getStorageToken(),
          useValue: {
            increment: (key: string, ttl: number, limit: number) =>
              rateStore.increment(key, ttl, limit),
          },
        },
        { provide: APP_GUARD, useClass: IpRateLimitGuard },
        { provide: APP_GUARD, useClass: AccessTokenGuard },
        { provide: APP_GUARD, useClass: ApiRateLimitGuard },
        { provide: APP_INTERCEPTOR, useClass: ApiResponseInterceptor },
        { provide: APP_FILTER, useClass: ErrorFilter },
      ],
    }).compile();
    app = module.createNestApplication({ logger: false });
    setNestApp(app);
    await app.init();
    server = app.getHttpServer() as Server;
  });
  afterAll(async () => {
    await app?.close();
  });

  beforeEach(() => {
    jest.clearAllMocks();
    cached.clear();
    sessions.rows.clear();
    rateStore = new MemoryRateLimitStorage();
    restaurants = [ownerA, ownerB].map((owner, index) =>
      Object.assign(new RestaurantEntity(), {
        id: uuid(10 + index),
        ownerId: owner.id,
        owner,
        name: `Restaurant ${index}`,
        deliveryFee: 1000,
      }),
    );
    dishes = restaurants.map((restaurant, index) =>
      Object.assign(new DishEntity(), {
        id: uuid(20 + index),
        restaurantId: restaurant.id,
        restaurant,
        name: `Dish ${index}`,
        price: 10000,
      }),
    );
    orders = [clientA, clientB].map((customer, index) =>
      Object.assign(new OrderEntity(), {
        id: uuid(30 + index),
        customerId: customer.id,
        customer,
        restaurant: restaurants[index],
        restaurantId: restaurants[index].id,
        status: OrderStatus.Pending,
        driverId: null,
        items: [],
      }),
    );
    reviews = [clientA, clientB].map((client, index) =>
      Object.assign(new ReviewEntity(), {
        id: uuid(40 + index),
        client,
        clientId: client.id,
        orderId: orders[index].id,
        score: 5,
      }),
    );
    reviewRepo.findOneByFilters.mockResolvedValue(null);
    paymentRepo.findOneByFilters.mockResolvedValue(null);
    userRepo.findByIdOrThrow.mockImplementation((id: string) =>
      Promise.resolve(requireEntity(users.find((user) => user.id === id))),
    );
    orderRepo.findManyWithOmitNotJoinedProps.mockResolvedValue([orders[0]]);
    orderRepo.find.mockResolvedValue([]);
    dishRepo.findManyWithOmitNotJoinedProps.mockResolvedValue([dishes[0]]);
  });

  it.each([
    'missing',
    'forged',
    'expired',
    'wrong-type',
    'missing-sub',
    'deleted-user',
    'revoked',
  ])('rejects %s access tokens before resource access', async (kind) => {
    let access = token(clientA);
    if (kind === 'forged')
      access = jwt.sign(
        { sub: clientA.id, type: TokenType.ACCESS },
        { secret: 'different-secret' },
      );
    if (kind === 'expired')
      access = jwt.sign(
        { sub: clientA.id, type: TokenType.ACCESS },
        { secret, expiresIn: -1 },
      );
    if (kind === 'wrong-type')
      access = jwt.sign(
        { sub: clientA.id, type: TokenType.REFRESH },
        { secret },
      );
    if (kind === 'missing-sub')
      access = jwt.sign({ type: TokenType.ACCESS }, { secret });
    if (kind === 'deleted-user')
      access = jwt.sign({ sub: uuid(99), type: TokenType.ACCESS }, { secret });
    if (kind === 'revoked')
      sessions.rows.delete(clientA.id);
    const req = request(server).get(`/orders/${uuid(30)}`);
    if (kind !== 'missing') req.set('Authorization', `Bearer ${access}`);
    await req.expect(401);
    expect(
      orderRepo.findOneWithOmitNotJoinedPropsOrThrow,
    ).not.toHaveBeenCalled();
  });

  it('denies client A access to client B order; the owner can read it', async () => {
    await request(server)
      .get(`/orders/${uuid(31)}`)
      .auth(token(clientA), { type: 'bearer' })
      .expect(403);
    const response = await request(server)
      .get(`/orders/${uuid(31)}`)
      .auth(token(clientB), { type: 'bearer' })
      .expect(200);
    expect(JSON.stringify(response.body as unknown)).not.toContain(
      'PASSWORD_HASH_MUST_NOT_LEAK',
    );
  });
  it('ignores a userId query when listing client orders', async () => {
    await request(server)
      .get(`/orders?userId=${clientB.id}`)
      .auth(token(clientA), { type: 'bearer' })
      .expect(200);
    expect(orderRepo.findManyWithOmitNotJoinedProps).toHaveBeenCalledWith(
      { customer: { id: clientA.id } },
      { restaurant: true },
      { createdAt: 'DESC' },
    );
  });
  it('restricts owner order list to their restaurants', async () => {
    await request(server)
      .get('/orders')
      .auth(token(ownerA), { type: 'bearer' })
      .expect(200);
    expect(orderRepo.find).toHaveBeenCalledWith({
      where: { restaurant: { id: In([uuid(10)]) } },
      relations: ['restaurant', 'customer'],
      order: { createdAt: 'DESC' },
    });
  });
  it('restricts delivery list to unassigned cooked or their assigned picked-up orders', async () => {
    await request(server)
      .get('/orders')
      .auth(token(driverA), { type: 'bearer' })
      .expect(200);
    expect(orderRepo.find).toHaveBeenCalledWith({
      where: [
        { status: OrderStatus.Cooked, driverId: IsNull() },
        { status: OrderStatus.PickedUp, driver: { id: driverA.id } },
      ],
      relations: ['restaurant', 'customer'],
      order: { createdAt: 'DESC' },
    });
  });
  it('denies owner A viewing or updating owner B restaurant order', async () => {
    await request(server)
      .get(`/orders/${uuid(31)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .expect(403);
    await request(server)
      .patch(`/orders/${uuid(31)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .send({ status: OrderStatus.Cooking })
      .expect(403);
    expect(orderRepo.save).not.toHaveBeenCalled();
  });
  it.each([clientA, clientB])(
    'denies client $id any status mutation',
    async (client) => {
      await request(server)
        .patch(`/orders/${uuid(31)}`)
        .auth(token(client), { type: 'bearer' })
        .send({ status: OrderStatus.Delivered })
        .expect(403);
      expect(orderRepo.save).not.toHaveBeenCalled();
    },
  );
  it('denies another driver viewing, stealing or completing an assigned order', async () => {
    Object.assign(orders[0], {
      status: OrderStatus.PickedUp,
      driverId: driverB.id,
      driver: driverB,
    });
    await request(server)
      .get(`/orders/${uuid(30)}`)
      .auth(token(driverA), { type: 'bearer' })
      .expect(403);
    for (const status of [OrderStatus.PickedUp, OrderStatus.Delivered]) {
      await request(server)
        .patch(`/orders/${uuid(30)}`)
        .auth(token(driverA), { type: 'bearer' })
        .send({ status })
        .expect(403);
    }
    expect(orderRepo.save).not.toHaveBeenCalled();
    expect(orders[0].driverId).toBe(driverB.id);
  });
  it('denies premature pickup and owner reset after pickup', async () => {
    await request(server)
      .patch(`/orders/${uuid(30)}`)
      .auth(token(driverA), { type: 'bearer' })
      .send({ status: OrderStatus.PickedUp })
      .expect(403);
    Object.assign(orders[0], {
      status: OrderStatus.PickedUp,
      driverId: driverB.id,
      driver: driverB,
    });
    await request(server)
      .patch(`/orders/${uuid(30)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .send({ status: OrderStatus.Cooked })
      .expect(403);
    expect(orderRepo.save).not.toHaveBeenCalled();
  });
  it('allows the intended owner-to-assigned-driver lifecycle', async () => {
    for (const status of [OrderStatus.Cooking, OrderStatus.Cooked]) {
      await request(server)
        .patch(`/orders/${uuid(30)}`)
        .auth(token(ownerA), { type: 'bearer' })
        .send({ status })
        .expect(200);
    }
    for (const status of [OrderStatus.PickedUp, OrderStatus.Delivered]) {
      const response = await request(server)
        .patch(`/orders/${uuid(30)}`)
        .auth(token(driverA), { type: 'bearer' })
        .send({ status })
        .expect(200);
      expect(JSON.stringify(response.body as unknown)).not.toContain(
        'PASSWORD_HASH_MUST_NOT_LEAK',
      );
    }
    expect(orders[0].driverId).toBe(driverA.id);
  });
  it('rejects a dish from a different restaurant before saving an order', async () => {
    dishRepo.findManyWithOmitNotJoinedProps.mockResolvedValue([dishes[1]]);
    await request(server)
      .post('/orders')
      .auth(token(clientA), { type: 'bearer' })
      .send({ restaurantId: uuid(10), items: [{ dishId: uuid(21) }] })
      .expect(400);
    expect(orderRepo.save).not.toHaveBeenCalled();
  });

  it('denies owner A changing owner B restaurant but permits owner B', async () => {
    await request(server)
      .patch(`/restaurants/${uuid(11)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .send({ name: 'Changed' })
      .expect(403);
    expect(restaurantRepo.save).not.toHaveBeenCalled();
    await request(server)
      .patch(`/restaurants/${uuid(11)}`)
      .auth(token(ownerB), { type: 'bearer' })
      .send({ name: 'Changed' })
      .expect(200);
  });
  it('denies creating a dish in another owner restaurant', async () => {
    await request(server)
      .post(`/restaurants/${uuid(11)}/dishes`)
      .auth(token(ownerA), { type: 'bearer' })
      .send({ name: 'Dish', price: 10, description: 'Test' })
      .expect(403);
    expect(dishRepo.save).not.toHaveBeenCalled();
  });
  it('denies owner A changing or deleting owner B dish', async () => {
    await request(server)
      .patch(`/restaurants/${uuid(11)}/dishes/${uuid(21)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .send({ name: 'Changed' })
      .expect(403);
    await request(server)
      .delete(`/dishes/${uuid(21)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .expect(403);
    expect(dishRepo.save).not.toHaveBeenCalled();
    expect(dishRepo.softDelete).not.toHaveBeenCalled();
  });
  it('rejects a mismatched restaurantId/dishId pair', async () => {
    await request(server)
      .patch(`/restaurants/${uuid(10)}/dishes/${uuid(21)}`)
      .auth(token(ownerA), { type: 'bearer' })
      .send({ name: 'Changed' })
      .expect(404);
  });
  it('permits owner B editing and deleting their dish', async () => {
    await request(server)
      .patch(`/restaurants/${uuid(11)}/dishes/${uuid(21)}`)
      .auth(token(ownerB), { type: 'bearer' })
      .send({ name: 'Changed' })
      .expect(200);
    await request(server)
      .delete(`/dishes/${uuid(21)}`)
      .auth(token(ownerB), { type: 'bearer' })
      .expect(200);
  });
  it('preserves public browsing with categoryId pagination', async () => {
    restaurantRepo.paginate.mockResolvedValue({ data: [], total: 0 });
    await request(server)
      .get(`/restaurants?categoryId=${uuid(50)}&page=1&limit=10`)
      .expect(200);
    expect(restaurantRepo.paginate).toHaveBeenCalledWith(
      expect.objectContaining({ page: 1, limit: 10 }),
      { categoryId: uuid(50) },
    );
  });

  it('denies client A updating or deleting client B review', async () => {
    await request(server)
      .patch(`/reviews/${uuid(41)}`)
      .auth(token(clientA), { type: 'bearer' })
      .send({ score: 1 })
      .expect(403);
    await request(server)
      .delete(`/reviews/${uuid(41)}`)
      .auth(token(clientA), { type: 'bearer' })
      .expect(403);
    expect(reviewRepo.save).not.toHaveBeenCalled();
    expect(reviewRepo.softDelete).not.toHaveBeenCalled();
  });
  it('permits client B updating and deleting their review', async () => {
    const response = await request(server)
      .patch(`/reviews/${uuid(41)}`)
      .auth(token(clientB), { type: 'bearer' })
      .send({ score: 4 })
      .expect(200);
    expect(JSON.stringify(response.body as unknown)).not.toContain(
      'PASSWORD_HASH_MUST_NOT_LEAK',
    );
    await request(server)
      .delete(`/reviews/${uuid(41)}`)
      .auth(token(clientB), { type: 'bearer' })
      .expect(200);
  });
  it.each(['other-client', 'different-restaurant', 'undelivered', 'duplicate'])(
    'rejects %s review creation',
    async (kind) => {
      orders[0].status = OrderStatus.Delivered;
      let user = clientA;
      let restaurantId = uuid(10);
      if (kind === 'other-client') user = clientB;
      if (kind === 'different-restaurant') restaurantId = uuid(11);
      if (kind === 'undelivered') orders[0].status = OrderStatus.Cooked;
      if (kind === 'duplicate')
        reviewRepo.findOneByFilters.mockResolvedValue(reviews[0]);
      await request(server)
        .post('/reviews')
        .auth(token(user), { type: 'bearer' })
        .send({ orderId: uuid(30), restaurantId, score: 5, reviewText: 'Good' })
        .expect(kind === 'duplicate' ? 409 : 400);
      expect(reviewRepo.save).not.toHaveBeenCalled();
    },
  );
  it('creates a delivered-order review without exposing nested credentials', async () => {
    orders[0].status = OrderStatus.Delivered;
    const response = await request(server)
      .post('/reviews')
      .auth(token(clientA), { type: 'bearer' })
      .send({
        orderId: uuid(30),
        restaurantId: uuid(10),
        score: 5,
        reviewText: 'Good',
      })
      .expect(201);
    expect(JSON.stringify(response.body as unknown)).not.toContain(
      'PASSWORD_HASH_MUST_NOT_LEAK',
    );
  });

  it('denies paying another client order and permits the real customer', async () => {
    const body = { orderId: uuid(31), transactionId: 'mock-transaction' };
    await request(server)
      .post('/payments')
      .auth(token(clientA), { type: 'bearer' })
      .send(body)
      .expect(400);
    expect(paymentRepo.save).not.toHaveBeenCalled();
    const response = await request(server)
      .post('/payments')
      .auth(token(clientB), { type: 'bearer' })
      .send(body)
      .expect(201);
    expect(JSON.stringify(response.body as unknown)).not.toContain(
      'PASSWORD_HASH_MUST_NOT_LEAK',
    );
    expect(paymentRepo.save).toHaveBeenCalledWith(
      expect.objectContaining({
        restaurantId: uuid(11),
        user: expect.objectContaining({ id: clientB.id }) as unknown,
      }),
    );
  });
  it('denies duplicate payment', async () => {
    paymentRepo.findOneByFilters.mockResolvedValue(new PaymentEntity());
    await request(server)
      .post('/payments')
      .auth(token(clientA), { type: 'bearer' })
      .send({ orderId: uuid(30), transactionId: 'duplicate' })
      .expect(400);
    expect(paymentRepo.save).not.toHaveBeenCalled();
  });

  it.each(users)(
    'denies $role $id before entering the cached profile service',
    async (user) => {
      const cacheHit = jest
        .spyOn(app.get(UserService), 'getUser')
        .mockResolvedValue({ ...clientB });
      await request(server)
        .get(`/users/${user.id === clientA.id ? clientB.id : clientA.id}`)
        .auth(token(user), { type: 'bearer' })
        .expect(403);
      expect(userRepo.findByIdOrThrow).not.toHaveBeenCalled();
      expect(cacheHit).not.toHaveBeenCalled();
      cacheHit.mockRestore();
    },
  );
  it('returns explicit self profile fields and never password/hash, including legacy plain cached users', async () => {
    const cacheHit = jest
      .spyOn(app.get(UserService), 'getUser')
      .mockResolvedValueOnce({ ...clientA });
    const response = await request(server)
      .get(`/users/${clientA.id}`)
      .auth(token(clientA), { type: 'bearer' })
      .expect(200);
    expect(response.body as unknown).toEqual({
      success: true,
      data: {
        id: clientA.id,
        email: clientA.email,
        name: clientA.name,
        role: clientA.role,
        verified: true,
      },
    });
    expect(JSON.stringify(response.body as unknown)).not.toMatch(
      /password|PASSWORD_HASH_MUST_NOT_LEAK/i,
    );
    cacheHit.mockRestore();
  });
  it('updates only the authenticated profile and removes the new hash from JSON', async () => {
    userRepo.findByIdOrThrow.mockResolvedValueOnce({ ...clientA });
    const response = await request(server)
      .patch('/users/profile')
      .auth(token(clientA), { type: 'bearer' })
      .send({ name: 'Updated', password: 'NewPass123!' })
      .expect(200);
    expect(userRepo.save).toHaveBeenCalledWith(
      expect.objectContaining({
        id: clientA.id,
        password: 'HASHED_NewPass123!',
      }),
    );
    expect(JSON.stringify(response.body as unknown)).not.toMatch(
      /password|HASHED_|NewPass123/i,
    );
  });

  it.each([
    ['Client creating a restaurant', clientA, '/restaurants', { name: 'No' }],
    ['Delivery creating an order', driverA, '/orders', { items: [] }],
    ['Owner paying an order', ownerA, '/payments', { orderId: uuid(30) }],
    ['Owner creating a review', ownerA, '/reviews', { orderId: uuid(30) }],
    [
      'Delivery creating a dish',
      driverA,
      `/restaurants/${uuid(10)}/dishes`,
      { name: 'No' },
    ],
  ] as const)('enforces role: %s', async (_label, user, path, body) => {
    await request(server)
      .post(path)
      .auth(token(user), { type: 'bearer' })
      .send(body)
      .expect(403);
  });
  it('uses DB role rather than an injected JWT role', async () => {
    const access = jwt.sign(
      { ...sessions.claims(clientA.id), role: Role.OWNER },
      { secret, expiresIn: '1h' },
    );
    await request(server)
      .post('/restaurants')
      .auth(access, { type: 'bearer' })
      .send({ name: 'No' })
      .expect(403);
  });

  it.each([
    [
      '/auth/sign-up',
      clientA,
      {
        email: 'new@example.com',
        name: 'New',
        password: 'ValidPass123!',
        role: Role.CLIENT,
        id: clientB.id,
      },
    ],
    [
      '/restaurants',
      ownerA,
      {
        name: 'New',
        coverImg: 'url',
        address: 'Address',
        categoryId: uuid(50),
        deliveryFee: 0,
        minimumPrice: 0,
        id: uuid(11),
        ownerId: ownerB.id,
      },
    ],
    [
      `/restaurants/${uuid(10)}/dishes`,
      ownerA,
      {
        name: 'Dish',
        description: 'Test',
        price: 100,
        id: uuid(21),
        restaurantId: uuid(11),
      },
    ],
    [
      '/payments',
      clientA,
      {
        transactionId: 'mock',
        orderId: uuid(30),
        userId: clientB.id,
        amount: 1,
        paymentStatus: 'PAID',
      },
    ],
    [
      '/orders',
      clientA,
      {
        restaurantId: uuid(10),
        items: [{ dishId: uuid(20) }],
        customerId: clientB.id,
        clientId: clientB.id,
        status: OrderStatus.Delivered,
        total: 1,
      },
    ],
    ['/categories', clientA, { name: 'New', id: uuid(50) }],
  ] as const)(
    'rejects server-owned fields at POST %s',
    async (path, user, body) => {
      await request(server)
        .post(path)
        .auth(token(user), { type: 'bearer' })
        .send(body)
        .expect(400);
      expect(createUser).not.toHaveBeenCalled();
      for (const repo of [
        restaurantRepo,
        dishRepo,
        paymentRepo,
        orderRepo,
        categoryRepo,
      ])
        expect(repo.save).not.toHaveBeenCalled();
    },
  );
  it.each([
    ['/users/profile', clientA, { role: Role.OWNER, userId: clientB.id }],
    [`/restaurants/${uuid(10)}`, ownerA, { ownerId: ownerB.id }],
    [
      `/restaurants/${uuid(10)}/dishes/${uuid(20)}`,
      ownerA,
      { restaurantId: uuid(11) },
    ],
    [
      `/reviews/${uuid(40)}`,
      clientA,
      { clientId: clientB.id, orderId: uuid(31) },
    ],
  ] as const)(
    'rejects ownership changes at PATCH %s',
    async (path, user, body) => {
      await request(server)
        .patch(path)
        .auth(token(user), { type: 'bearer' })
        .send(body)
        .expect(400);
    },
  );
  it('rejects nested order-option mass assignment', async () => {
    await request(server)
      .post('/orders')
      .auth(token(clientA), { type: 'bearer' })
      .send({
        restaurantId: uuid(10),
        items: [
          {
            dishId: uuid(20),
            options: [{ name: 'Spicy', extra: 0, ownerId: ownerB.id }],
          },
        ],
      })
      .expect(400);
    expect(orderRepo.save).not.toHaveBeenCalled();
  });
  it('hides database errors and stack traces in every environment', async () => {
    userRepo.findByIdOrThrow.mockRejectedValueOnce(
      Object.assign(new Error('DB_PASSWORD=DO_NOT_EXPOSE'), {
        query: 'PRIVATE_SQL',
      }),
    );
    const response = await request(server)
      .get(`/users/${clientA.id}?token=PRIVATE_QUERY`)
      .auth(token(clientA), { type: 'bearer' })
      .expect(500);
    expect(JSON.stringify(response.body as unknown)).not.toMatch(
      /DO_NOT_EXPOSE|PRIVATE_SQL|PRIVATE_QUERY|stack/,
    );
    expect(response.body as unknown).toEqual(
      expect.objectContaining({ message: 'Internal Server Error' }),
    );
  });
  it('preserves login access token and cookie without returning refresh token in JSON', async () => {
    const response = await request(server)
      .post('/auth/sign-in')
      .send({ email: clientA.email, password: 'ValidPass123!' })
      .expect(200);
    expect(response.body as unknown).toEqual({
      success: true,
      data: { accessToken: expect.any(String) as unknown },
    });
    expect(response.headers['set-cookie'] as unknown).toEqual(
      expect.arrayContaining([expect.stringContaining('refreshToken=')]),
    );
    expect(JSON.stringify(response.body as unknown)).not.toMatch(
      /refreshToken|password/,
    );
  });
  it('rejects incorrect login credentials', async () => {
    await request(server)
      .post('/auth/sign-in')
      .send({ email: clientA.email, password: 'incorrect' })
      .expect(401);
  });
  it.each(['/auth/sign-in/', '/AUTH/SIGN-IN'])(
    'preserves issuance on the registered auth route at %s',
    async (path) => {
      const response = await request(server)
        .post(path)
        .send({ email: clientA.email, password: 'ValidPass123!' })
        .expect(200);
      expect(response.body as unknown).toEqual({
        success: true,
        data: { accessToken: expect.any(String) as unknown },
      });
    },
  );
  it('requires a stored valid refresh cookie and rejects a revoked cookie', async () => {
    await request(server).post('/auth/refresh').expect(401);
    const refresh = jwt.sign(
      { sub: clientA.id, type: TokenType.REFRESH, jti: 'original' },
      { secret: refreshSecret, expiresIn: '1h' },
    );
    await request(server)
      .post('/auth/refresh')
      .set('Cookie', `refreshToken=${refresh}`)
      .expect(401);
    const login = await request(server).post('/auth/sign-in')
      .send({ email: clientA.email, password: 'ValidPass123!' }).expect(200);
    const cookie = login.headers['set-cookie'][0].split(';')[0];
    const response = await request(server)
      .post('/auth/refresh').set('Cookie', cookie).expect(200);
    expect(response.body as unknown).toEqual({
      success: true,
      data: { accessToken: expect.any(String) as unknown },
    });
    await request(server)
      .post('/auth/refresh')
      .set('Cookie', cookie)
      .expect(401);
  });
});
