// @app/storage — shared storage helpers

export const STORAGE_KEYS = {
  AUTH_TOKEN:    'auth_token',
  REFRESH_TOKEN: 'refresh_token',
  USER:          'user',
  THEME:         'theme',
  LOCALE:        'locale',
} as const;

export type StorageKey = (typeof STORAGE_KEYS)[keyof typeof STORAGE_KEYS];

export interface StorageAdapter {
  getItem(key: string): string | null | Promise<string | null>;
  setItem(key: string, value: string): void | Promise<void>;
  removeItem(key: string): void | Promise<void>;
}

/** Web localStorage adapter — safe in Next.js (guards against SSR) */
export const webStorageAdapter: StorageAdapter = {
  getItem(key)        { return typeof window === 'undefined' ? null : localStorage.getItem(key); },
  setItem(key, value) { if (typeof window !== 'undefined') localStorage.setItem(key, value); },
  removeItem(key)     { if (typeof window !== 'undefined') localStorage.removeItem(key); },
};
