import type { NextConfig } from 'next';
import path from 'node:path';
import {prepare, verify} from './localization/prepare.cjs';

// Development infrastructure shared by every template project.
// Keep routing, integrations, plugins, and application options in next.config.ts.
export function buildAllowedDevOrigins(): string[] {
  const origins = new Set(['**.localhost', '*.trycloudflare.com']);
  const projectHost = process.env.PROJECT_HOST?.trim();
  if (projectHost) {
    origins.add(projectHost.endsWith('.localhost') ? projectHost : `${projectHost}.localhost`);
  }
  for (const value of [process.env.NEXT_PUBLIC_URL, process.env.CLOUDFLARE_TUNNEL_URL]) {
    if (!value) continue;
    try {
      origins.add(new URL(value).hostname);
    } catch {
      // Ignore malformed optional URLs; local wildcard coverage remains available.
    }
  }
  return [...origins];
}

// Main-domain backend routes mirror the local proxy; addresses are project-owned.
export function buildBackendRewrites() {
  const value = process.env.BACKEND_URL?.trim() || process.env.NEXT_PUBLIC_API_URL?.trim();
  if (!value || !/^https?:\/\//i.test(value)) return [];
  const target = new URL(value);
  if (target.username || target.password || target.search || target.hash) throw new Error('Backend URL must not contain credentials, query or fragment');
  return [{source: '/admin/', destination: `${target.origin}/admin/`},
    ...['admin', 'static', 'media'].map(prefix => ({source: `/${prefix}/:path${prefix === 'admin' ? '+' : '*'}`,
      destination: `${target.origin}/${prefix}/:path${prefix === 'admin' ? '+/' : '*'}`}))];
}

export function buildBackendRedirects(trailingSlash = false, skipNormalization = false) {
  const rules = [{source: '/admin:slash((?!/)$)', destination: '/admin/', permanent: false}];
  if (skipNormalization) return rules;
  const exempt = '(?!admin(?:/|$)|static(?:/|$)|media(?:/|$)|\\.well-known(?:/|$))';
  if (trailingSlash) rules.push(
    {source: `/:file(${exempt}(?:[^/]+/)*[^/]+\\.\\w+)/`, destination: '/:file', permanent: true},
    {source: `/:page(${exempt}(?:[^/]+/)*[^/\\.]+)`, destination: '/:page/', permanent: true});
  else rules.push({source: `/:page(${exempt}.+)/`, destination: '/:page', permanent: true});
  return rules;
}

export function withSharedDevConfig(projectConfig: NextConfig): NextConfig {
  if (process.env.NODE_ENV === 'production') verify(process.cwd());
  else prepare(process.cwd());
  const projectWebpack = projectConfig.webpack;
  const projectRewrites = projectConfig.rewrites;
  const projectRedirects = projectConfig.redirects;
  const projectHeaders = projectConfig.headers;
  return {
    ...projectConfig,
    skipTrailingSlashRedirect: true,
    async redirects() {
      return [...(projectRedirects ? await projectRedirects() : []),
        ...buildBackendRedirects(projectConfig.trailingSlash, projectConfig.skipTrailingSlashRedirect)];
    },
    async rewrites() {
      const existing = projectRewrites ? await projectRewrites() : [];
      const backend = buildBackendRewrites();
      return Array.isArray(existing)
        ? {beforeFiles: backend, afterFiles: existing, fallback: []}
        : {...existing, beforeFiles: [...backend, ...(existing.beforeFiles ?? [])]};
    },
    async headers() {
      return [...(projectHeaders ? await projectHeaders() : []), {
        source: '/admin/:path*', headers: [
          {key: 'Cache-Control', value: 'private, no-store'},
          {key: 'X-Robots-Tag', value: 'noindex, nofollow'},
        ],
      }];
    },
    outputFileTracingRoot: projectConfig.outputFileTracingRoot ?? process.cwd(),
    outputFileTracingIncludes: {...projectConfig.outputFileTracingIncludes, '/*': [...(projectConfig.outputFileTracingIncludes?.['/*'] ?? []), './messages/automatic/*.json']},
    allowedDevOrigins: [...new Set([
      ...buildAllowedDevOrigins(),
      ...(projectConfig.allowedDevOrigins ?? []),
    ])],
    webpack(config, context) {
      const result = projectWebpack ? projectWebpack(config, context) : config;
      result.module.rules.push({test: /\.[jt]sx?$/, enforce: 'pre',
        include: [path.join(process.cwd(), 'app'), path.join(process.cwd(), 'components')],
        exclude: [/\.(test|spec)\./],
        use: [{loader: path.join(process.cwd(), 'localization/loader.cjs')}],
      });
      if (context.dev) {
        // Host-to-VM bind mounts need polling for both server and browser builds.
        // Retain application-specific watcher exclusions and other webpack options.
        result.watchOptions = {
          ...result.watchOptions,
          poll: result.watchOptions?.poll ?? 500,
          aggregateTimeout: result.watchOptions?.aggregateTimeout ?? 300,
          ignored: result.watchOptions?.ignored ?? ['**/node_modules/**', '**/.next/**'],
        };
      }
      return result;
    },
  };
}
