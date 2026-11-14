import { Global, Module } from '@nestjs/common';
import { EventsGateway } from './events.gateway';
import { OrderRepositoryModule } from '../modules/order/repository/order-repository.module';
import { UserRepositoryModule } from '../modules/user/repository/user-repository.module';

@Global() // 어디서든 쓸 수 있게 Global로 선언
@Module({
  imports: [OrderRepositoryModule, UserRepositoryModule],
  providers: [EventsGateway],
  exports: [EventsGateway], // OrderService에서 주입받기 위해 export 필수
})
export class EventsModule {}
