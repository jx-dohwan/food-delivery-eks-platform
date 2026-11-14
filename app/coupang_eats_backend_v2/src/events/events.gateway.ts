import {
  WebSocketGateway,
  WebSocketServer,
  SubscribeMessage,
  OnGatewayConnection,
  OnGatewayDisconnect,
  MessageBody,
  ConnectedSocket,
  WsException,
} from '@nestjs/websockets';
import { type OnModuleDestroy } from '@nestjs/common';
import { Server, Socket } from 'socket.io';
import { isUUID } from 'class-validator';
import { TokenService } from '../core/jwt/jwt.service';
import { TokenType } from '../core/jwt/jwt.interface';
import { UserRepository } from '../modules/user/repository/user.repository';
import { OrderRepository } from '../modules/order/repository/order.repository';
import { assertOrderAccess } from '../modules/order/order-authorization';
import { User } from '../entities/user/user.entity';
import { Role } from '../entities/user/user.interface';
import { OrderStatus } from '../common/type/common.interface';
import { WorkloadLifecycleService } from '../core/health/workload-lifecycle.service';

@WebSocketGateway({ cors: { origin: '*' } })
export class EventsGateway
  implements OnGatewayConnection, OnGatewayDisconnect, OnModuleDestroy
{
  private readonly disconnectTimers = new Map<
    string,
    ReturnType<typeof setTimeout>
  >();
  @WebSocketServer()
  server: Server;

  constructor(
    private readonly tokenService: TokenService,
    private readonly userRepository: UserRepository,
    private readonly orderRepository: OrderRepository,
    private readonly lifecycle: WorkloadLifecycleService,
  ) {}

  onModuleDestroy(): void {
    this.lifecycle.beginDrain();
    for (const timer of this.disconnectTimers.values()) clearTimeout(timer);
    this.disconnectTimers.clear();
    this.server?.disconnectSockets(true);
  }

  async handleConnection(client: Socket): Promise<void> {
    try {
      const { user, expiresAt } = await this.authenticate(client);
      if (this.lifecycle.isDraining)
        throw new WsException('Service unavailable');
      const timer = setTimeout(
        () => client.disconnect(true),
        Math.min(expiresAt - Date.now(), 2_147_483_647),
      );
      timer.unref();
      this.disconnectTimers.set(client.id, timer);
      if (user.role === Role.DELIVERY) await client.join(Role.DELIVERY);
    } catch {
      client.disconnect(true);
    }
  }

  handleDisconnect(client: Socket): void {
    // Socket.IO removes room membership on disconnect.
    const timer = this.disconnectTimers.get(client.id);
    if (timer) clearTimeout(timer);
    this.disconnectTimers.delete(client.id);
  }

  // 1. 사용자별 방 입장 (Owner 알림용)
  @SubscribeMessage('joinUserRoom')
  async handleJoinUserRoom(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { userId: string; role: Role },
  ) {
    const { user } = await this.authenticate(client);
    if (data?.userId !== user.id || data?.role !== user.role) {
      throw new WsException('You can only join your own user room.');
    }
    await client.join(`${user.role}:${user.id}`);
  }

  // 2. 주문별 방 입장 (상태 업데이트 및 위치 추적용)
  @SubscribeMessage('joinOrderRoom')
  async handleJoinOrderRoom(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { orderId: string },
  ) {
    const { user } = await this.authenticate(client);
    const order = await this.authorizeOrder(user, data?.orderId);
    await client.join(`order:${order.id}`);
  }

  // 3. 배달원 위치 실시간 중계 (DB 저장 X, 소켓으로만 전달)
  // 프론트엔드에서 구글 지도로 얻은 좌표를 이 이벤트로 쏘면 됩니다.
  @SubscribeMessage('updateDriverLocation')
  async handleDriverLocation(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { orderId: string; lat: number; lng: number },
  ) {
    const { user } = await this.authenticate(client);
    const order = await this.authorizeOrder(user, data?.orderId);
    if (
      user.role !== Role.DELIVERY ||
      order.driverId !== user.id ||
      order.status !== OrderStatus.PickedUp
    ) {
      throw new WsException('Only the assigned driver can update location.');
    }
    if (!Number.isFinite(data.lat) || !Number.isFinite(data.lng)) {
      throw new WsException('Invalid coordinates.');
    }
    const roomName = `order:${order.id}`;
    // 해당 주문 방에 있는 사람(고객)에게만 좌표 전송
    await this.emitAuthorizedRoom(roomName, 'driverLocation', {
      lat: data.lat,
      lng: data.lng,
    }, client.id);
  }

  // All private producers must pass this boundary. Each WAS validates its
  // local recipients against shared authoritative state immediately before
  // emit. No cached handshake verdict or cross-replica revocation notification
  // is trusted. Packets already authorized/in flight are not retractable.
  async emitAuthorizedRoom(room: string, event: string, payload: unknown, excludeSocketId?: string): Promise<void> {
    if (!this.server || this.lifecycle.isDraining) return;
    const ids = [...(this.server.sockets.adapter.rooms.get(room) ?? [])];
    for (const id of ids) {
      if (id === excludeSocketId) continue;
      const socket = this.server.sockets.sockets.get(id);
      if (!socket?.connected) continue;
      try {
        const { user } = await this.authenticate(socket);
        if (room.startsWith('order:')) await this.authorizeOrder(user, room.slice(6));
        else if (room === Role.DELIVERY) {
          if (user.role !== Role.DELIVERY) throw new WsException('Access denied');
        } else if (room !== `${user.role}:${user.id}`) throw new WsException('Access denied');
        // Socket may have left while asynchronous permission checks ran.
        if (socket.connected && socket.rooms.has(room) && !this.lifecycle.isDraining) socket.emit(event, payload);
      } catch { socket.disconnect(true); }
    }
  }

  private async authenticate(
    client: Socket,
  ): Promise<{ user: User; expiresAt: number }> {
    if (this.lifecycle.isDraining) throw new WsException('Service unavailable');
    const auth: unknown = client.handshake.auth;
    const header = client.handshake.headers.authorization;
    const accessToken =
      typeof auth === 'object' &&
      auth !== null &&
      'accessToken' in auth &&
      typeof auth.accessToken === 'string'
        ? auth.accessToken
        : header?.startsWith('Bearer ')
          ? header.slice(7)
          : undefined;
    if (!accessToken) throw new WsException('Authentication required.');
    try {
      const { payload, expired } =
        await this.tokenService.verifyAccessToken(accessToken);
      if (
        expired ||
        payload.type !== TokenType.ACCESS ||
        typeof payload.sub !== 'string' ||
        !isUUID(payload.sub) ||
        typeof payload.exp !== 'number' ||
        !Number.isFinite(payload.exp)
      )
        throw new Error('Invalid token');
      const user = await this.userRepository.findOneByFilters({
        id: payload.sub,
      });
      if (!user) throw new Error('User not found');
      return { user, expiresAt: payload.exp * 1000 };
    } catch {
      throw new WsException('Authentication required.');
    }
  }

  private async authorizeOrder(user: User, orderId: string) {
    if (typeof orderId !== 'string' || !isUUID(orderId)) {
      throw new WsException('Invalid order ID.');
    }
    try {
      const order =
        await this.orderRepository.findOneWithOmitNotJoinedPropsOrThrow(
          { id: orderId },
          { restaurant: true },
        );
      // Available orders can be browsed by drivers, but only assigned drivers
      // may subscribe to the persistent room and receive future location data.
      assertOrderAccess(user, order, false);
      return order;
    } catch {
      throw new WsException('You cannot access this order.');
    }
  }
}
