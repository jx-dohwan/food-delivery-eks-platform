import { Column, Entity, Index, PrimaryColumn } from 'typeorm';

// One current login per user, preserving the existing U06 contract.
// Expired rows authorize nothing; no raw JWT/password/email is persisted here.
@Entity('auth_session_state')
export class AuthSessionState {
  @PrimaryColumn({ name: 'user_id', type: 'varchar', length: 36, collation: 'utf8mb4_bin' })
  userId: string;
  @Column({ type: 'varchar', length: 36, collation: 'utf8mb4_bin' })
  sid: string;
  @Column({ name: 'refresh_hash', type: 'varchar', length: 64, collation: 'utf8mb4_bin' })
  refreshHash: string;
  @Index('idx_auth_session_expiry')
  @Column({ name: 'expires_at_ms', type: 'bigint' })
  expiresAtMs: string;
}
