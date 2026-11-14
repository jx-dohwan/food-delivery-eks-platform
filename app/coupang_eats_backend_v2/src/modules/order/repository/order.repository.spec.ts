import { NotFoundException } from '@nestjs/common';
import { EntityManager } from 'typeorm';
import { OrderRepository } from './order.repository';
import { OrderEntity } from '../../../entities/order/order.entity';

describe('order update row locking', () => {
  it('loads the order with a pessimistic write lock and authorization relations', async () => {
    const repository = new OrderRepository(OrderEntity, {} as EntityManager);
    const order = Object.assign(new OrderEntity(), { id: 'order-A' });
    const findOne = jest.spyOn(repository, 'findOne').mockResolvedValue(order);
    expect(await repository.findForStatusUpdate('order-A')).toBe(order);
    expect(findOne).toHaveBeenCalledWith({
      where: { id: 'order-A' },
      relations: { restaurant: true, driver: true },
      lock: { mode: 'pessimistic_write' },
    });
  });
  it('preserves the missing-resource 404 policy', async () => {
    const repository = new OrderRepository(OrderEntity, {} as EntityManager);
    jest.spyOn(repository, 'findOne').mockResolvedValue(null);
    await expect(repository.findForStatusUpdate('unknown')).rejects.toThrow(
      NotFoundException,
    );
  });
});
