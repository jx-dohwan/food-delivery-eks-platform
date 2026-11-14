import { NotFoundException } from '@nestjs/common';
import { GenericTypeOrmRepository } from '../../../core/database/typeorm/generic-typeorm.repository';
import { OrderEntity } from '../../../entities/order/order.entity';
import { CustomRepository } from '../../../../libs/common/typeorm.ex/typeorm-ex.decorator';

@CustomRepository(OrderEntity)
export class OrderRepository extends GenericTypeOrmRepository<OrderEntity> {
  // Called inside editOrderStatus's transaction. Two drivers cannot claim one row.
  async findForStatusUpdate(id: string): Promise<OrderEntity> {
    const order = await this.findOne({
      where: { id },
      relations: { restaurant: true, driver: true },
      lock: { mode: 'pessimistic_write' },
    });
    if (!order) throw new NotFoundException('Not found');
    return order;
  }
}
