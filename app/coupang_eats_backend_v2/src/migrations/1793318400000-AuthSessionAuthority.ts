import { MigrationInterface, QueryRunner } from 'typeorm';

export class AuthSessionAuthority1793318400000 implements MigrationInterface {
  name = 'AuthSessionAuthority1793318400000';
  async up(runner: QueryRunner): Promise<void> {
    await runner.query(`CREATE TABLE auth_session_state (
      user_id varchar(36) COLLATE utf8mb4_bin NOT NULL,
      sid varchar(36) COLLATE utf8mb4_bin NOT NULL,
      refresh_hash varchar(64) COLLATE utf8mb4_bin NOT NULL,
      expires_at_ms bigint NOT NULL,
      PRIMARY KEY (user_id), INDEX idx_auth_session_expiry (expires_at_ms)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin`);
  }
  async down(_runner: QueryRunner): Promise<void> {
    // Restoring a Redis-only release would restore the vulnerability. Do not
    // silently destroy the authority or its revocations as a rollback shortcut.
    throw new Error('Auth authority rollback requires an approved invalidation and data-retention procedure');
  }
}
