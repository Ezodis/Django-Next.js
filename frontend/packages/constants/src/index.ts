// @elitecar/constants
// Shared constants across web and mobile apps

export const APP_NAME = 'EliteCar';
export const APP_VERSION = '1.0.0';

// API
export const API_TIMEOUT_MS = 30_000;

// Map defaults
export const DEFAULT_LATITUDE = 0;
export const DEFAULT_LONGITUDE = 0;
export const DEFAULT_ZOOM = 13;

// Ride statuses
export const RIDE_STATUS = {
  PENDING: 'pending',
  ACCEPTED: 'accepted',
  IN_PROGRESS: 'in_progress',
  COMPLETED: 'completed',
  CANCELLED: 'cancelled',
} as const;

export type RideStatus = (typeof RIDE_STATUS)[keyof typeof RIDE_STATUS];
