/**
 * Shared utility functions for EliteCar
 */

// ─── Location / Nominatim helpers ─────────────────────────────────────────────

export interface NearbyPlace {
  name: string;
  fullAddress: string;
  distance: number; // meters
  type: string;
  lat: number;
  lng: number;
}

/** Emoji icons keyed by OSM place type */
export const PLACE_CATEGORY_ICONS: Record<string, string> = {
  aerodrome: '✈️', airport: '✈️',
  station: '🚉', railway: '🚉',
  hospital: '🏥',
  mall: '🛒', supermarket: '🛒',
  university: '🎓', college: '🎓',
  stadium: '🏟️',
  theatre: '🎭', cinema: '🎬',
  museum: '🏛️', hotel: '🏨',
  restaurant: '🍽️', cafe: '☕',
  bank: '🏦', pharmacy: '💊',
  default: '📍',
};

/** Return the best emoji for a given OSM place type string */
export function getPlaceCategoryIcon(type: string): string {
  const lower = type.toLowerCase();
  for (const [key, icon] of Object.entries(PLACE_CATEGORY_ICONS)) {
    if (lower.includes(key)) return icon;
  }
  return PLACE_CATEGORY_ICONS.default;
}

/** Nominatim API response item shape */
type NominatimResult = Array<{
  display_name: string;
  lat: string;
  lon: string;
  type?: string;
  class?: string;
}>;

/**
 * Search places via Nominatim
 * Works in both browser and React Native (uses global fetch)
 */
export async function searchNominatim(
  query: string,
  lat: number,
  lng: number,
  signal?: AbortSignal,
  skipViewbox?: boolean
): Promise<NearbyPlace[]> {
  const viewboxParam = (!skipViewbox && lat !== 0 && lng !== 0)
    ? `&viewbox=${lng - 0.5},${lat + 0.5},${lng + 0.5},${lat - 0.5}`
    : '';
  const url =
    `https://nominatim.openstreetmap.org/search?format=json` +
    `&q=${encodeURIComponent(query)}` +
    ((!skipViewbox && lat !== 0 && lng !== 0) ? `&lat=${lat}&lon=${lng}` : '') +
    `&limit=10&bounded=0` +
    viewboxParam;

  const res = await fetch(url, {
    headers: { 'User-Agent': 'EliteCar/1.0' },
    signal,
  });

  if (!res.ok) return [];

  const data = (await res.json()) as NominatimResult;

  return data
    .map(p => {
      const pLat = parseFloat(p.lat);
      const pLon = parseFloat(p.lon);
      return {
        name: p.display_name.split(',')[0].trim(),
        fullAddress: p.display_name,
        distance: calculateDistanceMeters(lat, lng, pLat, pLon),
        type: p.type || p.class || 'place',
        lat: pLat,
        lng: pLon,
      };
    })
    .sort((a, b) => a.distance - b.distance)
    .slice(0, 8);
}

/**
 * Fetch nearby places via Nominatim (no query — uses bounding box)
 */
export async function fetchNearbyPlacesNominatim(
  lat: number,
  lng: number
): Promise<NearbyPlace[]> {
  const url =
    `https://nominatim.openstreetmap.org/search?format=json&q=place` +
    `&lat=${lat}&lon=${lng}&limit=8&bounded=1` +
    `&viewbox=${lng - 0.05},${lat + 0.05},${lng + 0.05},${lat - 0.05}`;

  try {
    const res = await fetch(url, { headers: { 'User-Agent': 'EliteCar/1.0' } });
    if (!res.ok) return [];

    const data = (await res.json()) as NominatimResult;

    return data
      .map(p => {
        const pLat = parseFloat(p.lat);
        const pLon = parseFloat(p.lon);
        return {
          name: p.display_name.split(',')[0].trim(),
          fullAddress: p.display_name,
          distance: calculateDistanceMeters(lat, lng, pLat, pLon),
          type: p.type || p.class || 'place',
          lat: pLat,
          lng: pLon,
        };
      })
      .sort((a, b) => a.distance - b.distance);
  } catch {
    return [];
  }
}

/**
 * Calculate distance between two coordinates in meters (Haversine)
 */
export function calculateDistanceMeters(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ─── General utilities ────────────────────────────────────────────────────────

/**
 * Format currency value
 */
export function formatCurrency(amount: number, currency: string = 'USD'): string {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
  }).format(amount);
}

/**
 * Format distance in meters to a human-readable string
 */
export function formatDistanceMeters(meters: number): string {
  return meters < 1000 ? `${Math.round(meters)}m` : `${(meters / 1000).toFixed(1)}km`;
}

/**
 * Format distance in km to a human-readable string
 */
export function formatDistance(distanceKm: number): string {
  return formatDistanceMeters(distanceKm * 1000);
}

/**
 * Calculate distance between two coordinates in km (Haversine formula)
 */
export function calculateDistance(
  lat1: number,
  lon1: number,
  lat2: number,
  lon2: number
): number {
  return calculateDistanceMeters(lat1, lon1, lat2, lon2) / 1000;
}

/**
 * Format date/time
 */
export function formatDateTime(timestamp: number | string | Date): string {
  const date = new Date(timestamp);
  return new Intl.DateTimeFormat('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date);
}

/**
 * Format date only
 */
export function formatDate(timestamp: number | string | Date): string {
  const date = new Date(timestamp);
  return new Intl.DateTimeFormat('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  }).format(date);
}

/**
 * Format time only
 */
export function formatTime(timestamp: number | string | Date): string {
  const date = new Date(timestamp);
  return new Intl.DateTimeFormat('en-US', {
    hour: '2-digit',
    minute: '2-digit',
  }).format(date);
}

/**
 * Validate email address
 */
export function isValidEmail(email: string): boolean {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return emailRegex.test(email);
}

/**
 * Validate phone number (basic validation)
 */
export function isValidPhone(phone: string): boolean {
  const phoneRegex = /^\+?[\d\s\-()]+$/;
  return phoneRegex.test(phone) && phone.replace(/\D/g, '').length >= 10;
}

/**
 * Debounce function
 */
export function debounce<T extends (...args: any[]) => any>(
  func: T,
  wait: number
): (...args: Parameters<T>) => void {
  let timeout: NodeJS.Timeout | null = null;
  return function executedFunction(...args: Parameters<T>) {
    const later = () => {
      timeout = null;
      func(...args);
    };
    if (timeout) clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

/**
 * Throttle function
 */
export function throttle<T extends (...args: any[]) => any>(
  func: T,
  limit: number
): (...args: Parameters<T>) => void {
  let inThrottle: boolean;
  return function executedFunction(...args: Parameters<T>) {
    if (!inThrottle) {
      func(...args);
      inThrottle = true;
      setTimeout(() => (inThrottle = false), limit);
    }
  };
}

/**
 * Deep clone object
 */
export function deepClone<T>(obj: T): T {
  return JSON.parse(JSON.stringify(obj));
}

/**
 * Generate random ID
 */
export function generateId(prefix: string = ''): string {
  const timestamp = Date.now();
  const random = Math.random().toString(36).substring(2, 11);
  return prefix ? `${prefix}_${timestamp}_${random}` : `${timestamp}_${random}`;
}

/**
 * Sleep/delay function
 */
export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Truncate string
 */
export function truncate(str: string, maxLength: number): string {
  if (str.length <= maxLength) return str;
  return str.substring(0, maxLength - 3) + '...';
}

/**
 * Capitalize first letter
 */
export function capitalize(str: string): string {
  if (!str) return str;
  return str.charAt(0).toUpperCase() + str.slice(1);
}

/**
 * Format phone number for display
 */
export function formatPhoneNumber(phone: string): string {
  const cleaned = phone.replace(/\D/g, '');
  if (cleaned.length === 10) {
    return `(${cleaned.slice(0, 3)}) ${cleaned.slice(3, 6)}-${cleaned.slice(6)}`;
  }
  return phone;
}
