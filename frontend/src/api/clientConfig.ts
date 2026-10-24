import type { CreateClientConfig } from '../client/client.gen';
import { timedFetch } from '../lib/runs/serverClock';
import { CHANNEL_HEADERS } from './constants';

/**
 * Same-origin requests; paths in the spec already carry the /api/v1 prefix. Every response
 * is a server-time sample (timers.md §5.1).
 */
export const createClientConfig: CreateClientConfig = (config) => ({
  ...config,
  baseUrl: '',
  headers: { ...CHANNEL_HEADERS },
  fetch: timedFetch(),
});
