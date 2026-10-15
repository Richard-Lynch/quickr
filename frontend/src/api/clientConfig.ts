import type { CreateClientConfig } from '../client/client.gen';

/** Same-origin requests; paths in the spec already carry the /api/v1 prefix. */
export const createClientConfig: CreateClientConfig = (config) => ({
  ...config,
  baseUrl: '',
  headers: {
    'X-Quicker-Channel': 'ui',
  },
});
