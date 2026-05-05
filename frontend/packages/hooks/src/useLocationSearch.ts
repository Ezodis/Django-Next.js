import { useState, useEffect, useCallback, useRef, useMemo } from 'react';
import {
  NearbyPlace,
  searchNominatim,
  fetchNearbyPlacesNominatim,
  getPlaceCategoryIcon,
} from '@elitecar/utils';

export interface LocationSuggestion {
  key: string;
  label: string;
  sublabel?: string;
  icon: string;
  isCurrentLocation?: boolean;
  place?: NearbyPlace;
}

export interface UseLocationSearchOptions {
  /** 'pickup' shows a "use current location" action; 'dropoff' does not */
  icon: 'pickup' | 'dropoff';
  /** Current typed value */
  value: string;
  /** Whether the input is focused */
  isFocused: boolean;
  /** User's current coordinates (optional) */
  currentCoords?: { lat: number; lng: number } | null;
  /** Current address string (for the "use current location" action) */
  currentAddress?: string;
  /** Debounce delay in ms (default 300) */
  debounceMs?: number;
}

export interface UseLocationSearchResult {
  suggestions: LocationSuggestion[];
  isSearching: boolean;
  isLoadingNearby: boolean;
  nearbyPlaces: NearbyPlace[];
}

/**
 * Shared location search hook — works in both web (React) and mobile (React Native).
 * Handles debounced Nominatim search + nearby places loading.
 */
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
    fetchNearbyPlacesNominatim(currentCoords.lat, currentCoords.lng)
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

      const lat = currentCoords?.lat ?? 0;
      const lng = currentCoords?.lng ?? 0;
      const noCoords = !currentCoords;

      try {
        const results = await searchNominatim(value, lat, lng, controller.signal, noCoords);
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

    // "Use current location" action — pickup only
    if (icon === 'pickup' && currentAddress) {
      items.push({
        key: '__current__',
        label: 'Poner ubicación actual',
        sublabel: currentAddress,
        icon: '📍',
        isCurrentLocation: true,
      });
    }

    // Active search results take priority
    if (value.length >= 2 && searchResults.length > 0) {
      searchResults.forEach(p => {
        const dist = p.distance < 1000
          ? `${Math.round(p.distance)}m`
          : `${(p.distance / 1000).toFixed(1)}km`;
        items.push({
          key: `sr_${p.lat}_${p.lng}`,
          label: p.name,
          sublabel: dist,
          icon: getPlaceCategoryIcon(p.type),
          place: p,
        });
      });
      return items;
    }

    // Default: nearby places
    nearbyPlaces.forEach(p => {
      const dist = p.distance < 1000
        ? `${Math.round(p.distance)}m`
        : `${(p.distance / 1000).toFixed(1)}km`;
      items.push({
        key: `nb_${p.lat}_${p.lng}`,
        label: p.name,
        sublabel: dist,
        icon: getPlaceCategoryIcon(p.type),
        place: p,
      });
    });

    return items;
  }, [icon, currentAddress, value, searchResults, nearbyPlaces]);

  return { suggestions, isSearching, isLoadingNearby, nearbyPlaces };
}
