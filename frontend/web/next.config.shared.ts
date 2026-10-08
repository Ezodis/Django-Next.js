import type { NextConfig } from 'next';

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

export function withSharedDevConfig(projectConfig: NextConfig): NextConfig {
  const projectWebpack = projectConfig.webpack;
  return {
    ...projectConfig,
    outputFileTracingRoot: projectConfig.outputFileTracingRoot ?? process.cwd(),
    allowedDevOrigins: [...new Set([
      ...buildAllowedDevOrigins(),
      ...(projectConfig.allowedDevOrigins ?? []),
    ])],
    webpack(config, context) {
      const result = projectWebpack ? projectWebpack(config, context) : config;
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
