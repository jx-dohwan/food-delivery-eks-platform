import { IsOptional, IsUUID } from 'class-validator';
import { PaginationRequest } from '../../../common/pagination/pagination.request';

// categoryId shares the query object with pagination and must be whitelisted.
export class RestaurantPaginationRequest extends PaginationRequest {
  @IsOptional()
  @IsUUID()
  categoryId?: string;
}
