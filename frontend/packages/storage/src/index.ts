// @elitecar/storage
// Shared storage helpers (web uses localStorage, mobile uses AsyncStorage via adapter)

export const STORAGE_KEYS = {
  AUTH_TOKEN: 'elitecar_auth_token',
  REFRESH_TOKEN: 'elitecar_refresh_token',
  USER: 'elitecar_user',
  THEME: 'elitecar_theme',
  LOCALE: 'elitecar_locale',
} as const;

export type StorageKey = (typeof STORAGE_KEYS)[keyof typeof STORAGE_KEYS];

/**
 * Simple in-memory storage adapter interface.
 * Web uses localStorage; mobile provides an AsyncStorage-backed adapter.
 */
export interface StorageAdapter {
  getItem(key: string): string | null | Promise<string | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem(key: string): void | Promise<void>;
}

/**
 * Web localStorage adapter (safe to import in Next.js — guards against SSR)
 */
export const webStorageAdapter: StorageAdapter = {
  getItem(key: string) {
    if (typeof window === 'undefined') return null;
    return localStorage.getItem(key);
  },
  setItem(key: string, value: string) {
    if (typeof window === 'undefined') return;
    localStorage.setItem(key, value);
  },
  removeItem(key: string) {
    if (typeof window === 'undefined') return;
    localStorage.removeItem(key);
  },
};
