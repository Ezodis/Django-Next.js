/**
 * Shared constants and configuration
 * Used by both web and mobile applications
 */

// API endpoints
export const API_ENDPOINTS = {
  CSRF: '/csrf/',
  USERS: '/users/',
  PAYMENTS: '/payments/',
  SUBSCRIPTIONS: '/subscriptions/',
} as const;

// App configuration (to be overridden by environment variables)
export const APP_CONFIG = {
  // These should be set via environment variables in actual use
  API_URL: process.env.NEXT_PUBLIC_API_URL || process.env.EXPO_PUBLIC_API_URL || '',
} as const;

// Error messages
export const ERROR_MESSAGES = {
  NETWORK_ERROR: 'Network error. Please check your connection and try again.',
  AUTH_ERROR: 'Authentication failed. Please log in again.',
  VALIDATION_ERROR: 'Please check your input and try again.',
  UNKNOWN_ERROR: 'An unexpected error occurred. Please try again.',
} as const;
