// @elitecar/api-client
// Shared API client for web and mobile apps

export interface RequestOptions extends RequestInit {
  params?: Record<string, string | number | boolean | undefined>;
}

export class ApiError extends Error {
  constructor(
    public status: number,
    public statusText: string,
    public body: unknown,
  ) {
    super(`API Error ${status}: ${statusText}`);
    this.name = 'ApiError';
  }
}

/**
 * Build a URL with optional query params
 */
function buildUrl(base: string, path: string, params?: RequestOptions['params']): string {
  const url = new URL(path, base);
  if (params) {
    Object.entries(params).forEach(([key, value]) => {
      if (value !== undefined) url.searchParams.set(key, String(value));
    });
  }
  return url.toString();
}

/**
 * Core fetch wrapper used by both web and mobile.
 * Pass `baseUrl` from environment (e.g. process.env.NEXT_PUBLIC_API_URL).
 */
export async function apiFetch<T>(
  baseUrl: string,
  path: string,
  options: RequestOptions = {},
): Promise<T> {
  const { params, headers, ...rest } = options;

  const url = buildUrl(baseUrl, path, params);

  const response = await fetch(url, {
    ...rest,
    headers: {
      'Content-Type': 'application/json',
      ...headers,
    },
  });

  if (!response.ok) {
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      body = await response.text();
    }
    throw new ApiError(response.status, response.statusText, body);
  }

  // 204 No Content
  if (response.status === 204) return undefined as T;

  return response.json() as Promise<T>;
}

/**
 * Create a typed API client bound to a base URL and optional auth token getter.
 */
export function createApiClient(
  baseUrl: string,
  getToken?: () => string | null | undefined,
) {
  async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
    const token = getToken?.();
    const authHeaders: Record<string, string> = token
      ? { Authorization: `Bearer ${token}` }
      : {};

    return apiFetch<T>(baseUrl, path, {
      ...options,
      headers: { ...authHeaders, ...(options.headers as Record<string, string>) },
    });
  }

  return {
    get: <T>(path: string, options?: RequestOptions) =>
      request<T>(path, { ...options, method: 'GET' }),

    post: <T>(path: string, body: unknown, options?: RequestOptions) =>
      request<T>(path, {
        ...options,
        method: 'POST',
        body: JSON.stringify(body),
      }),

    put: <T>(path: string, body: unknown, options?: RequestOptions) =>
      request<T>(path, {
        ...options,
        method: 'PUT',
        body: JSON.stringify(body),
      }),

    patch: <T>(path: string, body: unknown, options?: RequestOptions) =>
      request<T>(path, {
        ...options,
        method: 'PATCH',
        body: JSON.stringify(body),
      }),

    delete: <T>(path: string, options?: RequestOptions) =>
      request<T>(path, { ...options, method: 'DELETE' }),
  };
}
