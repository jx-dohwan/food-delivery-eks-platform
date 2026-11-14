import { ApiProperty } from '@nestjs/swagger';
import { User } from '../../../entities/user/user.entity';
import { Role } from '../../../entities/user/user.interface';

export class UserResponse {
  @ApiProperty()
  id: string;

  @ApiProperty()
  email: string;

  @ApiProperty()
  name: string;

  @ApiProperty({ enum: Role })
  role: Role;

  @ApiProperty()
  verified: boolean;

  static fromEntity(user: User): UserResponse {
    return Object.assign(new UserResponse(), {
      id: user.id,
      email: user.email,
      name: user.name,
      role: user.role,
      verified: user.verified,
    });
  }
}
