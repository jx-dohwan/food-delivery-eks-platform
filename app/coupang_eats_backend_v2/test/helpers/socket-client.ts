import { setTimeout as delay } from 'node:timers/promises';
// Real Engine.IO v4 / Socket.IO websocket transport using the existing ws dependency.
// Avoid installing or changing the application's dependency lockfile for a test client.
export class SocketWire {
  private ws: any;
  readonly events: Array<[string, any]> = [];
  disconnected = false;
  constructor(private readonly port: number, private readonly token: string) {}
  connect(): Promise<void> {
    const Ws = require('ws');
    return new Promise((resolve, reject) => {
      this.ws = new Ws(`ws://127.0.0.1:${this.port}/socket.io/?EIO=4&transport=websocket`);
      this.ws.on('error', reject);
      this.ws.on('close', () => { this.disconnected = true; });
      this.ws.on('message', (data: Buffer) => {
        const packet = data.toString();
        if (packet.startsWith('0')) this.ws.send('40' + JSON.stringify({ accessToken: this.token }));
        else if (packet.startsWith('40')) resolve();
        else if (packet === '2') this.ws.send('3');
        else if (packet.startsWith('42')) this.events.push(JSON.parse(packet.slice(2)));
      });
    });
  }
  send(event: string, data: unknown) { this.ws.send('42' + JSON.stringify([event, data])); }
  close() { this.ws?.terminate(); }
}
export async function eventually(check: () => boolean, timeout = 2500) {
  const until = Date.now() + timeout;
  while (!check()) {
    if (Date.now() > until) throw new Error('Local socket observation timed out');
    await delay(10);
  }
}
