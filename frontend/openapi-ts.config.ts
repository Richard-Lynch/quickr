import { defineConfig } from '@hey-api/openapi-ts';

export default defineConfig({
  input: '../openapi.json',
  output: 'src/client',
  plugins: [
    {
      name: '@hey-api/client-fetch',
      runtimeConfigPath: './src/api/clientConfig',
    },
    '@hey-api/typescript',
    {
      name: 'zod',
      // Accept any timezone-aware ISO datetime (the backend emits `Z` today, but
      // `+02:00` is equally valid input/output for AwareDatetime).
      dates: { offset: true },
      requests: true,
      responses: true,
    },
    {
      name: '@hey-api/sdk',
      validator: 'zod',
    },
    '@tanstack/react-query',
  ],
});
