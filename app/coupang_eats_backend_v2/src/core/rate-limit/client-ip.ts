import { BlockList, isIP } from 'node:net';
import type { IncomingHttpHeaders } from 'node:http';

export const RATE_PROXY_SETTINGS = 'rate-limit-proxy-settings';

function normalizeIp(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  let address = raw.trim();
  // ALB may append a client port. Ports must never create distinct rate keys.
  if (address.startsWith('[')) {
    const bracketed = /^\[([^\]]+)\](?::\d+)?$/.exec(address);
    if (!bracketed) return undefined;
    address = bracketed[1];
  } else if (/^\d+\.\d+\.\d+\.\d+:\d+$/.test(address))
    address = address.split(':')[0];
  if (isIP(address) === 4) return address;
  if (isIP(address) !== 6 || address.includes('%')) return undefined;
  address = new URL(`http://[${address}]/`).hostname.slice(1, -1);
  const mapped = /^::ffff:([a-f\d]+):([a-f\d]+)$/.exec(address);
  if (mapped) {
    const high = parseInt(mapped[1], 16);
    const low = parseInt(mapped[2], 16);
    return `${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`;
  }
  return address;
}

function cidrList(value: string | undefined, defaults: string[]): string[] {
  return value === undefined
    ? defaults
    : value
        .split(',')
        .map((v) => v.trim())
        .filter(Boolean);
}

function blockList(cidrs: string[]): BlockList {
  const list = new BlockList();
  for (const cidr of cidrs) {
    const [address, bits] = cidr.split('/');
    const family = isIP(address);
    const prefix = Number(bits);
    if (
      !family ||
      bits === undefined ||
      !Number.isInteger(prefix) ||
      prefix <= 0 ||
      prefix > (family === 4 ? 32 : 128)
    ) {
      throw new Error('Invalid rate-limit trusted proxy CIDR');
    }
    list.addSubnet(address, prefix, family === 4 ? 'ipv4' : 'ipv6');
  }
  return list;
}

export class RateLimitProxySettings {
  private readonly alb: BlockList;
  private readonly web: BlockList;

  constructor(
    albCidrs = cidrList(process.env.RATE_LIMIT_ALB_PROXY_CIDRS, []),
    webCidrs = cidrList(process.env.RATE_LIMIT_WEB_PROXY_CIDRS, []),
  ) {
    // Only deployment-supplied proxy networks are trusted.
    this.alb = blockList(albCidrs);
    this.web = blockList(webCidrs);
  }

  isAlb(address: string): boolean {
    return this.alb.check(address, isIP(address) === 6 ? 'ipv6' : 'ipv4');
  }
  isWeb(address: string): boolean {
    return this.web.check(address, isIP(address) === 6 ? 'ipv6' : 'ipv4');
  }
  trustHop(raw: string, hop: number): boolean {
    const address = normalizeIp(raw);
    if (!address) return false;
    return hop === 0
      ? this.isWeb(address) || this.isAlb(address)
      : hop === 1 && this.isAlb(address);
  }
}

export function rateLimitClientIp(
  request: { headers: IncomingHttpHeaders; socket: { remoteAddress?: string } },
  settings: RateLimitProxySettings,
): string {
  const remote = normalizeIp(request.socket.remoteAddress);
  if (!remote) return 'unknown';
  const raw = request.headers['x-forwarded-for'];
  const forwarded = (Array.isArray(raw) ? raw.join(',') : (raw ?? '')).split(
    ',',
  );
  const last = normalizeIp(forwarded.at(-1));
  // Actual path: client → ALB (append) → Nginx (proxy_add_x_forwarded_for).
  if (settings.isWeb(remote) && last && settings.isAlb(last)) {
    return normalizeIp(forwarded.at(-2)) ?? remote;
  }
  // Also support a direct ALB target, without trusting user-supplied left entries.
  if (settings.isAlb(remote)) return last ?? remote;
  return remote;
}
