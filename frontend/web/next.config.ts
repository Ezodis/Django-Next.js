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
    '@elitecar/api-client',
    '@elitecar/constants',
    '@elitecar/storage',
    '@elitecar/theme',
    '@elitecar/types',
    '@elitecar/utils',
  ],

  // Webpack configuration for path aliases
  webpack: (config) => {
    config.resolve.alias = {
      ...config.resolve.alias,
      '@elitecar/api-client': path.resolve(__dirname, '../packages/api-client/src'),
      '@elitecar/constants': path.resolve(__dirname, '../packages/constants/src'),
      '@elitecar/storage': path.resolve(__dirname, '../packages/storage/src'),
      '@elitecar/theme': path.resolve(__dirname, '../packages/theme/src'),
      '@elitecar/types': path.resolve(__dirname, '../packages/types/src'),
      '@elitecar/utils': path.resolve(__dirname, '../packages/utils/src'),
    };
    return config;
  },

  // Rewrites for API routing
  async rewrites() {
    // In Docker with Traefik, don't rewrite - let browser call /api directly
    // Traefik will route /api requests to the backend service
    return [];
  },
};

export default nextConfig;
