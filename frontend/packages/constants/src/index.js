"use strict";
/**
 * Shared constants and configuration for EliteCar
 * Used by both web and mobile applications
 */
Object.defineProperty(exports, "__esModule", { value: true });
exports.ERROR_MESSAGES = exports.APP_CONFIG = exports.DEFAULTS = exports.RIDE_STATUS = exports.RIDE_TYPES = exports.API_ENDPOINTS = exports.DISTANCE_CONSTANTS = exports.TIME_CONSTANTS = exports.STORAGE_KEYS = void 0;
// Storage keys
exports.STORAGE_KEYS = {
    RIDE_SEARCH_DATA: 'elitecar_search_data',
    SESSION_ID: 'elitecar_session_id',
    DRIVER_LOGIN: 'elitecar_driver_login',
    DRIVER_RADIUS: 'elitecar_driver_radius',
    DRIVER_ACTIVE_RIDE: 'elitecar_driver_active_ride',
    PASSENGER_ACTIVE_RIDE: 'elitecar_passenger_active_ride',
};
// Time constants (in milliseconds)
exports.TIME_CONSTANTS = {
    DRIVER_LOGIN_EXPIRY_MS: 30 * 24 * 60 * 60 * 1000, // 30 days
    PASSENGER_RIDE_EXPIRY_MS: 24 * 60 * 60 * 1000, // 24 hours
    RIDE_DATA_EXPIRY_MS: 7 * 24 * 60 * 60 * 1000, // 7 days
    DRIVER_ACTIVE_RIDE_EXPIRY_MS: 24 * 60 * 60 * 1000, // 24 hours
};
// Distance constants
exports.DISTANCE_CONSTANTS = {
    MAX_DRIVER_RADIUS_KM: 50,
    DEFAULT_DRIVER_RADIUS_KM: 10,
};
// API endpoints
exports.API_ENDPOINTS = {
    CSRF: '/csrf/',
    RIDES: '/rides/',
    DRIVERS: '/drivers/',
    USERS: '/users/',
    PAYMENTS: '/payments/',
    SUBSCRIPTIONS: '/subscriptions/',
};
// Ride types
exports.RIDE_TYPES = {
    ELITERIDE: 'elitecar',
    PREMIUM: 'premium',
    ECONOMY: 'economy',
};
// Ride status values
exports.RIDE_STATUS = {
    REQUESTED: 'requested',
    MATCHED: 'matched',
    ARRIVING: 'arriving',
    PASSENGER_ONBOARD: 'passenger_onboard',
    COMPLETED: 'completed',
    CANCELLED: 'cancelled',
};
// Default values
exports.DEFAULTS = {
    SELECTED_RIDE: exports.RIDE_TYPES.ELITERIDE,
    PAYMENT_METHOD: 'visa-1234',
};
// App configuration (to be overridden by environment variables)
exports.APP_CONFIG = {
    // These should be set via environment variables in actual use
    API_URL: process.env.NEXT_PUBLIC_API_URL || process.env.EXPO_PUBLIC_API_URL || '',
    STRIPE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY ||
        process.env.EXPO_PUBLIC_STRIPE_PUBLISHABLE_KEY ||
        '',
    GOOGLE_MAPS_API_KEY: process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY ||
        process.env.EXPO_PUBLIC_GOOGLE_MAPS_API_KEY ||
        '',
};
// Error messages
exports.ERROR_MESSAGES = {
    NETWORK_ERROR: 'Network error. Please check your connection and try again.',
    AUTH_ERROR: 'Authentication failed. Please log in again.',
    VALIDATION_ERROR: 'Please check your input and try again.',
    UNKNOWN_ERROR: 'An unexpected error occurred. Please try again.',
};
//# sourceMappingURL=index.js.map