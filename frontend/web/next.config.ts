// next.config.ts
import { NextConfig } from 'next';
import path from 'path';

const nextConfig: NextConfig = {
  trailingSlash: true,
  images: {
    unoptimized: true,
  },
  typescript: {
    ignoreBuildErrors: true,
  },
  reactStrictMode: false,

  // Transpile shared packages
  transpilePackages: [
    '@app/api-client',
    '@app/constants',
    '@app/storage',
    '@app/theme',
    '@app/types',
    '@app/utils',
  ],

  // Webpack path aliases for shared packages
  webpack: (config) => {
    config.resolve.alias = {
      ...config.resolve.alias,
      '@app/api-client': path.resolve(__dirname, '../packages/api-client/src'),
      '@app/constants':  path.resolve(__dirname, '../packages/constants/src'),
      '@app/storage':    path.resolve(__dirname, '../packages/storage/src'),
      '@app/theme':      path.resolve(__dirname, '../packages/theme/src'),
      '@app/types':      path.resolve(__dirname, '../packages/types/src'),
      '@app/utils':      path.resolve(__dirname, '../packages/utils/src'),
    };
    return config;
  },

  // Rewrites for API routing
  async rewrites() {
    // In Docker with Traefik, don't rewrite — Traefik routes /api to the backend
    return [];
  },
};

export default nextConfig;
