import { ServiceUnavailableException } from '@nestjs/common';
import { DataSource } from 'typeorm';
import { writeEvent } from '../logger/safe-event';

export interface AuthorityRecord { sid: string; refresh_hash: string }
export abstract class SessionAuthority {
  abstract current(userId: string): Promise<AuthorityRecord | null>;
  abstract put(userId: string, sid: string, hash: string, ttl: number): Promise<void>;
  abstract rotate(userId: string, sid: string, previous: string, next: string, ttl: number): Promise<boolean>;
  abstract revoke(userId: string, sid: string): Promise<boolean>;
}

// The existing Aurora writer is the authority. Never read a lagging replica or
// the ambient business transaction's repeatable-read snapshot for revocation.
// Each mutation is a single autocommit statement on the writer, not a distributed
// Redis/SQL transaction. An uncertain commit is never compensated with old state.
export class MysqlSessionAuthority extends SessionAuthority {
  private failed = false;
  constructor(private readonly source: DataSource, private readonly emit = writeEvent) { super(); }
  private async query(sql: string, params: unknown[]): Promise<any> {
    let runner: ReturnType<DataSource['createQueryRunner']> | undefined;
    try {
      if (!this.source.isInitialized) throw new Error('Unavailable');
      runner = this.source.createQueryRunner('master');
      const result = await runner.query(sql, params);
      if (this.failed) this.emit('database.ready', 'INFO', { phase: 'query' });
      this.failed = false;
      return result;
    } catch {
      if (!this.failed) this.emit('database.failed', 'ERROR', { phase: 'query', error_type: 'ServiceUnavailableException' });
      this.failed = true;
      throw new ServiceUnavailableException('Authentication temporarily unavailable');
    } finally { if (runner) await runner.release().catch(() => undefined); }
  }
  async current(userId: string): Promise<AuthorityRecord | null> {
    const rows = await this.query('SELECT sid, refresh_hash FROM auth_session_state WHERE user_id = ? AND expires_at_ms > UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000', [userId]);
    return rows[0] ?? null;
  }
  async put(userId: string, sid: string, hash: string, ttl: number): Promise<void> {
    await this.query('INSERT INTO auth_session_state (user_id, sid, refresh_hash, expires_at_ms) VALUES (?, ?, ?, UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 + ?) ON DUPLICATE KEY UPDATE sid = VALUES(sid), refresh_hash = VALUES(refresh_hash), expires_at_ms = VALUES(expires_at_ms)', [userId, sid, hash, ttl * 1000]);
  }
  async rotate(userId: string, sid: string, previous: string, next: string, ttl: number): Promise<boolean> {
    const result = await this.query('UPDATE auth_session_state SET refresh_hash = ?, expires_at_ms = UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000 + ? WHERE user_id = ? AND sid = ? AND refresh_hash = ? AND expires_at_ms > UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3)) * 1000', [next, ttl * 1000, userId, sid, previous]);
    return result.affectedRows === 1;
  }
  async revoke(userId: string, sid: string): Promise<boolean> {
    const result = await this.query('DELETE FROM auth_session_state WHERE user_id = ? AND sid = ?', [userId, sid]);
    return result.affectedRows === 1;
  }
}
