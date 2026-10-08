import path from 'node:path';
import { withSharedDevConfig } from './next.config.shared';
import type { NextConfig } from 'next';


const nextConfig: NextConfig = {
  images: {
    unoptimized: true,
  },
  reactStrictMode: false,


  webpack: (config, { dev }) => {
    // Add path alias for shared mobile code
    config.resolve = config.resolve || {};
    config.resolve.alias = {
      ...config.resolve.alias,
      '@shared': path.join(__dirname, 'shared'),
    };

    if (dev) {
      config.watchOptions = {
        ...config.watchOptions,
        ignored: ['**/node_modules/**', '**/.next/**'],
      };
    }
    return config;
  },
};

export default withSharedDevConfig(nextConfig);