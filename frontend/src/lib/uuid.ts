/**
 * RFC 4122 v4 UUID. `crypto.randomUUID` only exists in secure contexts (https /
 * localhost), so fall back to `getRandomValues`, which works everywhere.
 */
export function uuid(): string {
  const c = globalThis.crypto;
  if (typeof c.randomUUID === 'function') {
    try {
      return c.randomUUID();
    } catch {
      // insecure context — fall through
    }
  }
  const b = c.getRandomValues(new Uint8Array(16));
  b[6] = ((b[6] ?? 0) & 0x0f) | 0x40;
  b[8] = ((b[8] ?? 0) & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
