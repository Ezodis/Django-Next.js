import path from 'node:path';
import { withSharedDevConfig } from './next.config.shared';
import type { NextConfig } from 'next';


const nextConfig: NextConfig = {
  images: {
    unoptimized: true,
  },
  reactStrictMode: false,


  async headers() {
    return [
      {
        source: '/nancy',
        headers: [
          { key: 'Cache-Control', value: 'no-store, no-cache, must-revalidate' },
          { key: 'Pragma', value: 'no-cache' },
        ],
      },
      {
        source: '/resources/:path*',
        headers: [
          { key: 'Cache-Control', value: 'no-store, no-cache, must-revalidate' },
        ],
      },
    ];
  },

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
        ignored: ['**/node_modules/**', '**/.next/**', '**/public/bookcovers/**'],
      };
    }
    return config;
  },
};

export default withSharedDevConfig(nextConfig);