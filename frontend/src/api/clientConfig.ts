import type { CreateClientConfig } from '../client/client.gen';
import { CHANNEL_HEADERS } from './constants';

/** Same-origin requests; paths in the spec already carry the /api/v1 prefix. */
export const createClientConfig: CreateClientConfig = (config) => ({
  ...config,
  baseUrl: '',
  headers: { ...CHANNEL_HEADERS },
});
