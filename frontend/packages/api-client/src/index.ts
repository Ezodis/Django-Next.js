/**
 * Platform-agnostic API client for EliteCar
 * Works with both web (Next.js) and mobile (React Native) platforms
 */

import { API_ENDPOINTS, ERROR_MESSAGES } from '@elitecar/constants';
import type { ApiResponse } from '@elitecar/types';

export interface ApiClientConfig {
  baseUrl?: string;
  getAuthToken?: () => Promise<string | null>;
  onAuthError?: () => void;
}

/**
 * Platform-agnostic HTTP client using native fetch API
 */
export class ApiClient {
  private config: ApiClientConfig;
  private csrfToken: string | null = null;

  constructor(config: ApiClientConfig = {}) {
    this.config = config;
  }

  /**
   * Get the base URL for API requests
   * 
   * Uses platform-specific prefixes but same variable name:
   * - Next.js: NEXT_PUBLIC_API_URL
   * - Expo: EXPO_PUBLIC_API_URL
   * 
   * This allows using the same value across platforms while respecting
   * framework requirements for public environment variables.
   */
  private getBaseUrl(): string {
    if (this.config.baseUrl) {
      return this.config.baseUrl;
    }

    // Get API URL from environment (platform-specific prefix, same variable name)
    const envApiUrl = 
      (typeof process !== 'undefined' && process.env?.NEXT_PUBLIC_API_URL) ||
      (typeof process !== 'undefined' && process.env?.EXPO_PUBLIC_API_URL);
    
    if (envApiUrl) {
      console.log('✅ API URL configured:', envApiUrl);
      return envApiUrl;
    }

    // Development fallback - use relative path
    if (typeof process !== 'undefined' && process.env?.NODE_ENV === 'development') {
      console.log('ℹ️ Using development fallback: /api');
      return '/api';
    }

    // Production without configured URL - use relative path
    console.warn(
      '⚠️ API URL not configured. Set NEXT_PUBLIC_API_URL (web) or EXPO_PUBLIC_API_URL (mobile)'
    );
    return '/api';
  }

  /**
   * Build full URL from path
   */
  buildUrl(path: string): string {
    const baseUrl = this.getBaseUrl();
    const normalizedPath = path.startsWith('/') ? path : `/${path}`;
    return `${baseUrl}${normalizedPath}`;
  }

  /**
   * Fetch CSRF token from the server
   */
  async getCSRFToken(): Promise<string> {
    // Return cached token if available
    if (this.csrfToken) {
      return this.csrfToken;
    }

    try {
      const url = this.buildUrl(API_ENDPOINTS.CSRF);
      console.log('🔗 Fetching CSRF token from:', url);

      const response = await fetch(url, {
        credentials: 'include',
        cache: 'no-cache',
      });

      if (response.ok) {
        const data = await response.json();
        this.csrfToken = data.csrfToken || '';
        return this.csrfToken || '';
      }
    } catch (error) {
      console.error('❌ Error fetching CSRF token:', error);
    }
    this.csrfToken = '';
    return '';
  }

  /**
   * Clear cached CSRF token
   */
  clearCSRFToken(): void {
    this.csrfToken = null;
  }

  /**
   * Make an authenticated fetch request
   */
  async fetchWithAuth(url: string, options: RequestInit = {}): Promise<Response> {
    const defaultOptions: RequestInit = {
      credentials: 'include',
      headers: {
        'Content-Type': 'application/json',
        ...options.headers,
      },
      cache: 'no-cache',
    };

    // Add CSRF token for non-GET requests
    if (options.method && options.method !== 'GET') {
      const csrfToken = await this.getCSRFToken();
      if (csrfToken) {
        defaultOptions.headers = {
          ...defaultOptions.headers,
          'X-CSRFToken': csrfToken,
        };
      }
    }

    // Add authentication token if available
    if (this.config.getAuthToken) {
      try {
        const authToken = await this.config.getAuthToken();
        if (authToken) {
          defaultOptions.headers = {
            ...defaultOptions.headers,
            'Authorization': `Bearer ${authToken}`,
          };
        }
      } catch (error) {
        console.error('Error getting auth token:', error);
      }
    }

    try {
      const response = await fetch(url, {
        ...defaultOptions,
        ...options,
        headers: {
          ...defaultOptions.headers,
          ...options.headers,
        },
      });

      // Handle authentication errors
      if (response.status === 401 && this.config.onAuthError) {
        this.config.onAuthError();
      }

      return response;
    } catch (error) {
      console.error('Network error:', error);
      throw new Error(ERROR_MESSAGES.NETWORK_ERROR);
    }
  }

  /**
   * Parse API response
   */
  private async parseResponse<T>(response: Response): Promise<ApiResponse<T>> {
    try {
      const data = await response.json();
      
      if (!response.ok) {
        return {
          error: data.error || data.message || `Request failed with status ${response.status}`,
        };
      }

      return { data };
    } catch (error) {
      if (!response.ok) {
        return {
          error: `Request failed with status ${response.status}`,
        };
      }
      return {
        error: ERROR_MESSAGES.UNKNOWN_ERROR,
      };
    }
  }

  // Convenience methods

  /**
   * Make a GET request
   * Returns parsed ApiResponse with data/error structure
   */
  async get<T = any>(path: string): Promise<ApiResponse<T>> {
    const url = this.buildUrl(path);
    const response = await this.fetchWithAuth(url);
    return this.parseResponse<T>(response);
  }

  /**
   * Make a GET request and return raw Response
   * Use this for backward compatibility with code expecting Response.ok and Response.json()
   * @deprecated Use get() with ApiResponse format instead
   */
  async getRaw(path: string, options: RequestInit = {}): Promise<Response> {
    const url = this.buildUrl(path);
    return this.fetchWithAuth(url, options);
  }

  /**
   * Make a POST request
   */
  async post<T = any>(path: string, data?: unknown): Promise<ApiResponse<T>> {
    const url = this.buildUrl(path);
    const response = await this.fetchWithAuth(url, {
      method: 'POST',
      body: data ? JSON.stringify(data) : undefined,
    });
    return this.parseResponse<T>(response);
  }

  /**
   * Make a PUT request
   */
  async put<T = any>(path: string, data?: unknown): Promise<ApiResponse<T>> {
    const url = this.buildUrl(path);
    const response = await this.fetchWithAuth(url, {
      method: 'PUT',
      body: data ? JSON.stringify(data) : undefined,
    });
    return this.parseResponse<T>(response);
  }

  /**
   * Make a PATCH request
   */
  async patch<T = any>(path: string, data?: unknown): Promise<ApiResponse<T>> {
    const url = this.buildUrl(path);
    const response = await this.fetchWithAuth(url, {
      method: 'PATCH',
      body: data ? JSON.stringify(data) : undefined,
    });
    return this.parseResponse<T>(response);
  }

  /**
   * Make a DELETE request
   */
  async delete<T = any>(path: string): Promise<ApiResponse<T>> {
    const url = this.buildUrl(path);
    const response = await this.fetchWithAuth(url, {
      method: 'DELETE',
    });
    return this.parseResponse<T>(response);
  }
}

// Create a default instance for convenience
export const apiClient = new ApiClient();

// Export the class for custom instances
export default ApiClient;
