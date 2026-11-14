import { DataSource } from 'typeorm';
import { InitialSchema1767667794370 } from '../../src/migrations/1767667794370-InitialSchema';
import { AuthSessionState } from '../../src/entities/auth/auth-session-state.entity';
import { AuthSessionAuthority1793318400000 } from '../../src/migrations/1793318400000-AuthSessionAuthority';
export async function localSessionDatabase() {
  const port = Number(process.env.POLICY_TEST_MYSQL_PORT);
  if (process.env.POLICY_TEST_EPHEMERAL !== 'true' || !Number.isInteger(port) || port <= 0) throw new Error('Explicit local MySQL fixture required');
  const source = new DataSource({ type: 'mysql', host: '127.0.0.1', port,
    username: 'auth_test', password: 'synthetic-local-test-only', database: 'auth_test',
    entities: [AuthSessionState], migrations: [InitialSchema1767667794370, AuthSessionAuthority1793318400000], synchronize: false, logging: false,
    connectorPackage: 'mysql2', extra: { connectionLimit: 8, connectTimeout: 1000, waitForConnections: false } });
  await source.initialize(); await source.runMigrations(); return source;
}
