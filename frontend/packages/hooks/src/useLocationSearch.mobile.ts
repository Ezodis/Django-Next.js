/**
 * useLocationSearch — mobile (React Native / Expo) version
 * Self-contained: no @elitecar/* imports so it can be synced directly to mobile apps.
 *
 * SOURCE OF TRUTH: frontend/packages/hooks/src/useLocationSearch.ts
 */
import { useState, useEffect, useRef, useMemo } from 'react';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface NearbyPlace {
  name: string;
  fullAddress: string;
  distance: number; // meters
  type: string;
  lat: number;
  lng: number;
}

export interface LocationSuggestion {
  key: string;
  label: string;
  sublabel?: string;
  icon: string;
  isCurrentLocation?: boolean;
  place?: NearbyPlace;
}

export interface UseLocationSearchOptions {
  icon: 'pickup' | 'dropoff';
  value: string;
  isFocused: boolean;
  currentCoords?: { lat: number; lng: number } | null;
  currentAddress?: string;
  debounceMs?: number;
}

export interface UseLocationSearchResult {
  suggestions: LocationSuggestion[];
  isSearching: boolean;
  isLoadingNearby: boolean;
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const CATEGORY_ICONS: Record<string, string> = {
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

function getPlaceIcon(type: string): string {
  const lower = type.toLowerCase();
  for (const [key, icon] of Object.entries(CATEGORY_ICONS)) {
    if (lower.includes(key)) return icon;
  }
  return CATEGORY_ICONS.default;
}

function calcDistanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

async function fetchNearby(lat: number, lng: number): Promise<NearbyPlace[]> {
  try {
    const url =
      `https://nominatim.openstreetmap.org/search?format=json&q=place` +
      `&lat=${lat}&lon=${lng}&limit=8&bounded=1` +
      `&viewbox=${lng - 0.05},${lat + 0.05},${lng + 0.05},${lat - 0.05}`;
    const res = await fetch(url, { headers: { 'User-Agent': 'EliteCar/1.0' } });
    if (!res.ok) return [];
    const data = await res.json() as Array<{ display_name: string; lat: string; lon: string; type?: string; class?: string }>;
    return data
      .map(p => {
        const pLat = parseFloat(p.lat);
        const pLon = parseFloat(p.lon);
        return {
          name: p.display_name.split(',')[0].trim(),
          fullAddress: p.display_name,
          distance: calcDistanceMeters(lat, lng, pLat, pLon),
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

async function searchPlaces(
  query: string,
  lat: number | null,
  lng: number | null,
  signal: AbortSignal
): Promise<NearbyPlace[]> {
  const hasCoords = lat !== null && lng !== null;
  const locationParams = hasCoords
    ? `&lat=${lat}&lon=${lng}&viewbox=${lng! - 0.5},${lat! + 0.5},${lng! + 0.5},${lat! - 0.5}`
    : '';
  const url =
    `https://nominatim.openstreetmap.org/search?format=json` +
    `&q=${encodeURIComponent(query)}` +
    locationParams +
    `&limit=10&bounded=0`;
  const res = await fetch(url, {
    headers: { 'User-Agent': 'EliteCar/1.0' },
    signal,
  });
  if (!res.ok) return [];
  const data = await res.json() as Array<{ display_name: string; lat: string; lon: string; type?: string; class?: string }>;
  return data
    .map(p => {
      const pLat = parseFloat(p.lat);
      const pLon = parseFloat(p.lon);
      return {
        name: p.display_name.split(',')[0].trim(),
        fullAddress: p.display_name,
        distance: hasCoords ? calcDistanceMeters(lat!, lng!, pLat, pLon) : 0,
        type: p.type || p.class || 'place',
        lat: pLat,
        lng: pLon,
      };
    })
    .sort((a, b) => a.distance - b.distance)
    .slice(0, 8);
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function useLocationSearch({
  icon,
  value,
  isFocused,
  currentCoords,
  currentAddress,
  debounceMs = 300,
}: UseLocationSearchOptions): UseLocationSearchResult {
  const [searchResults, setSearchResults] = useState<NearbyPlace[]>([]);
  const [nearbyPlaces, setNearbyPlaces] = useState<NearbyPlace[]>([]);
  const [isSearching, setIsSearching] = useState(false);
  const [isLoadingNearby, setIsLoadingNearby] = useState(false);

  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  // Load nearby places when coords become available
  useEffect(() => {
    if (!currentCoords) return;
    setIsLoadingNearby(true);
    fetchNearby(currentCoords.lat, currentCoords.lng)
      .then(setNearbyPlaces)
      .finally(() => setIsLoadingNearby(false));
  }, [currentCoords?.lat, currentCoords?.lng]);

  // Debounced search
  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (abortRef.current) abortRef.current.abort();

    if (!value || value.length < 2 || !isFocused) {
      setSearchResults([]);
      setIsSearching(false);
      return;
    }

    debounceRef.current = setTimeout(async () => {
      const controller = new AbortController();
      abortRef.current = controller;
      setIsSearching(true);

      const lat = currentCoords?.lat ?? null;
      const lng = currentCoords?.lng ?? null;

      try {
        const results = await searchPlaces(value, lat, lng, controller.signal);
        setSearchResults(results);
      } catch (e: any) {
        if (e?.name !== 'AbortError') setSearchResults([]);
      } finally {
        setIsSearching(false);
      }
    }, debounceMs);

    return () => {
      if (debounceRef.current) clearTimeout(debounceRef.current);
    };
  }, [value, isFocused, currentCoords?.lat, currentCoords?.lng, debounceMs]);

  const suggestions = useMemo<LocationSuggestion[]>(() => {
    const items: LocationSuggestion[] = [];

    if (icon === 'pickup' && currentAddress) {
      items.push({
        key: '__current__',
        label: 'Poner ubicación actual',
        sublabel: currentAddress,
        icon: '📍',
        isCurrentLocation: true,
      });
    }

    if (value.length >= 2 && searchResults.length > 0) {
      searchResults.forEach(p => {
        const dist = p.distance < 1000 ? `${Math.round(p.distance)}m` : `${(p.distance / 1000).toFixed(1)}km`;
        items.push({ key: `sr_${p.lat}_${p.lng}`, label: p.name, sublabel: dist, icon: getPlaceIcon(p.type), place: p });
      });
      return items;
    }

    nearbyPlaces.forEach(p => {
      const dist = p.distance < 1000 ? `${Math.round(p.distance)}m` : `${(p.distance / 1000).toFixed(1)}km`;
      items.push({ key: `nb_${p.lat}_${p.lng}`, label: p.name, sublabel: dist, icon: getPlaceIcon(p.type), place: p });
    });

    return items;
  }, [icon, currentAddress, value, searchResults, nearbyPlaces]);

  return { suggestions, isSearching, isLoadingNearby };
}
