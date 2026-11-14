import { ForbiddenException } from '@nestjs/common';
import { OrderStatus } from '../../common/type/common.interface';
import { OrderEntity } from '../../entities/order/order.entity';
import { User } from '../../entities/user/user.entity';
import { Role } from '../../entities/user/user.interface';

export function assertOrderAccess(
  user: User,
  order: Pick<OrderEntity, 'customerId' | 'restaurant' | 'driverId' | 'status'>,
  allowAvailableForPickup = true,
): void {
  switch (user.role) {
    case Role.CLIENT:
      if (order.customerId === user.id) return;
      break;
    case Role.OWNER:
      if (order.restaurant?.ownerId === user.id) return;
      break;
    case Role.DELIVERY:
      if (order.driverId === user.id) return;
      if (
        allowAvailableForPickup &&
        order.status === OrderStatus.Cooked &&
        !order.driverId
      )
        return;
      break;
  }
  throw new ForbiddenException('You cannot access this order.');
}
