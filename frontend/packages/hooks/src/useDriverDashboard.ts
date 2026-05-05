import { useState, useEffect, useCallback, useRef } from 'react';

export type RideStatus = 'matched' | 'arriving' | 'passenger_onboard' | 'completed';

export interface RideRequest {
  id: string;
  passengerName: string;
  pickupLocation: string;
  dropoffLocation: string;
  distance: string;
  estimatedFare: number;
  pickupCoords: { lat: number; lng: number };
  dropoffCoords?: { lat: number; lng: number };
}

export interface UseDriverDashboardOptions {
  apiClient: any;
  storage: any;
  onLocationUpdate?: (location: { lat: number; lng: number }) => void;
}

const DEFAULT_RADIUS_KM = 10;

async function getLocationFromIP(): Promise<{ lat: number; lng: number } | null> {
  try {
    const res = await fetch('https://ipapi.co/json/');
    if (res.ok) {
      const d = await res.json();
      if (d.lat && d.lon) return { lat: d.lat, lng: d.lon };
      if (d.latitude && d.longitude) return { lat: d.latitude, lng: d.longitude };
    }
  } catch { /* silent */ }
  return null;
}

export function useDriverDashboard({ apiClient, storage, onLocationUpdate }: UseDriverDashboardOptions) {
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [loginEmail, setLoginEmail] = useState('');
  const [isOnline, setIsOnline] = useState(false);
  const [rideRequests, setRideRequests] = useState<RideRequest[]>([]);
  const [activeRide, setActiveRide] = useState<RideRequest | null>(null);
  const [activeRideStatus, setActiveRideStatus] = useState<RideStatus>('matched');
  const [activeRideId, setActiveRideId] = useState<number | null>(null);
  const [driverLocation, setDriverLocation] = useState<{ lat: number; lng: number } | null>(null);
  const [searchRadius, setSearchRadius] = useState<number>(DEFAULT_RADIUS_KM);
  const [subscriptionStatus, setSubscriptionStatus] = useState<'active' | 'expired' | 'pending'>('active');
  
  const pollIntervalRef = useRef<any>(null);
  const previousRideCountRef = useRef<number>(0);
  const isInitialFetchRef = useRef<boolean>(true);

  // Calculate fare helper
  const calculateFare = useCallback(async (
    pickupLat: number | null,
    pickupLng: number | null,
    dropoffLat: number | null,
    dropoffLng: number | null
  ): Promise<number> => {
    if (pickupLat && pickupLng && dropoffLat && dropoffLng) {
      const R = 6371;
      const dLat = (dropoffLat - pickupLat) * Math.PI / 180;
      const dLng = (dropoffLng - pickupLng) * Math.PI / 180;
      const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
                Math.cos(pickupLat * Math.PI / 180) * Math.cos(dropoffLat * Math.PI / 180) *
                Math.sin(dLng / 2) * Math.sin(dLng / 2);
      const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
      const distance = R * c;
      
      try {
        const response = await apiClient.getRaw(`/rides/calculate-price/?distance=${distance}`);
        if (response.ok) {
          const data = await response.json();
          return data.price;
        }
      } catch (error) {
        console.error('Error fetching price:', error);
      }
    }
    return 225; // Default price
  }, [apiClient]);

  // Login handler
  const handleLogin = useCallback(async (email: string, password: string) => {
    const response = await apiClient.post('/drivers/login/', { email, password });
    
    if (response.ok) {
      const data = await response.json();
      
      if (!['active', 'inactive'].includes(data.driver.status)) {
        throw new Error(`Account status: ${data.driver.status}`);
      }
      
      setIsLoggedIn(true);
      setLoginEmail(email);
      storage.saveDriverLogin(email);
      
      return data;
    } else {
      const errorData = await response.json();
      throw new Error(errorData.message || 'Login failed');
    }
  }, [apiClient, storage]);

  // Logout handler
  const handleLogout = useCallback(async () => {
    if (isOnline && loginEmail) {
      try {
        await apiClient.post('/drivers/update-status/', {
          email: loginEmail,
          is_online: false,
        });
      } catch (error) {
        console.error('Error updating offline status:', error);
      }
    }
    
    storage.clearDriverLogin();
    setIsLoggedIn(false);
    setLoginEmail('');
    setIsOnline(false);
    setRideRequests([]);
    setActiveRide(null);
  }, [isOnline, loginEmail, apiClient, storage]);

  // Accept ride handler
  const handleAcceptRide = useCallback(async (ride: RideRequest) => {
    const rideId = parseInt(ride.id.replace('ride-', ''));
    
    try {
      const response = await apiClient.post(`/rides/${rideId}/accept/`, {
        email: loginEmail,
      });
      
      if (response.ok) {
        setActiveRide(ride);
        setActiveRideId(rideId);
        setActiveRideStatus('matched');
        setRideRequests([]);
        
        storage.saveDriverActiveRide({
          rideId,
          status: 'matched',
          pickupLocation: ride.pickupLocation,
          dropoffLocation: ride.dropoffLocation,
          pickupCoords: ride.pickupCoords,
          dropoffCoords: ride.dropoffCoords,
          estimatedFare: ride.estimatedFare,
          timestamp: Date.now()
        });
        
        return true;
      } else {
        const data = await response.json();
        throw new Error(data.message || 'Failed to accept ride');
      }
    } catch (error) {
      console.error('Error accepting ride:', error);
      throw error;
    }
  }, [loginEmail, apiClient, storage]);

  // Update ride status
  const handleUpdateRideStatus = useCallback(async (newStatus: RideStatus) => {
    if (!activeRideId) return;
    
    try {
      const response = await apiClient.post(`/rides/${activeRideId}/update-status/`, {
        status: newStatus,
      });
      
      if (response.ok) {
        setActiveRideStatus(newStatus);
        
        if (newStatus === 'completed') {
          storage.clearDriverActiveRide();
          setActiveRide(null);
          setActiveRideId(null);
        }
      }
    } catch (error) {
      console.error('Error updating ride status:', error);
      throw error;
    }
  }, [activeRideId, apiClient, storage]);

  // Fetch pending rides
  useEffect(() => {
    if (isOnline && isLoggedIn && !activeRide && loginEmail) {
      const fetchPendingRides = async () => {
        try {
          const response = await apiClient.getRaw(
            `/rides/pending/?email=${encodeURIComponent(loginEmail)}&radius=${searchRadius}`
          );
          
          if (response.ok) {
            const data = await response.json();
            
            const transformedRides: RideRequest[] = await Promise.all(
              data.rides.map(async (ride: any) => ({
                id: `ride-${ride.id}`,
                passengerName: ride.passenger_name || 'Pasajero',
                pickupLocation: ride.pickup_location,
                dropoffLocation: ride.dropoff_location,
                distance: ride.distance_to_pickup ? `${ride.distance_to_pickup.toFixed(1)} km` : 'N/A',
                estimatedFare: await calculateFare(ride.pickup_lat, ride.pickup_lng, ride.dropoff_lat, ride.dropoff_lng),
                pickupCoords: (ride.pickup_lat && ride.pickup_lng)
                  ? { lat: ride.pickup_lat, lng: ride.pickup_lng }
                  : { lat: 0, lng: 0 },
                dropoffCoords: (ride.dropoff_lat && ride.dropoff_lng)
                  ? { lat: ride.dropoff_lat, lng: ride.dropoff_lng }
                  : undefined,
              }))
            );
            
            const currentCount = transformedRides.length;
            const previousCount = previousRideCountRef.current;
            
            if (currentCount > previousCount && !isInitialFetchRef.current) {
              // New rides detected - could trigger notification here
            }
            
            if (isInitialFetchRef.current) {
              isInitialFetchRef.current = false;
            }
            
            previousRideCountRef.current = currentCount;
            setRideRequests(transformedRides);
          }
        } catch (error) {
          console.error('Error fetching pending rides:', error);
        }
      };
      
      fetchPendingRides();
      const interval = setInterval(fetchPendingRides, 1000);
      pollIntervalRef.current = interval;
      
      return () => {
        if (interval) clearInterval(interval);
      };
    } else {
      setRideRequests([]);
      if (pollIntervalRef.current) {
        clearInterval(pollIntervalRef.current);
        pollIntervalRef.current = null;
      }
    }
  }, [isOnline, isLoggedIn, activeRide, loginEmail, searchRadius, apiClient, calculateFare]);

  // Update driver location and online status
  useEffect(() => {
    if (!isLoggedIn || !loginEmail) return;
    
    const updateLocation = async (location: { lat: number; lng: number }) => {
      setDriverLocation(location);
      onLocationUpdate?.(location);
      
      if (isOnline) {
        try {
          await apiClient.post('/drivers/update-status/', {
            email: loginEmail,
            is_online: true,
            latitude: location.lat,
            longitude: location.lng,
          });
        } catch (error) {
          console.error('Error updating driver location:', error);
        }
      }
    };
    
    // Get initial location
    const geo = typeof navigator !== 'undefined' ? (navigator as any).geolocation : null;
    if (geo) {
      geo.getCurrentPosition(
        (position: GeolocationPosition) => {
          updateLocation({
            lat: position.coords.latitude,
            lng: position.coords.longitude,
          });
        },
        async () => {
          const ipLoc = await getLocationFromIP();
          if (ipLoc) updateLocation(ipLoc);
        }
      );
      
      // Update periodically
      const locationInterval = setInterval(() => {
        geo.getCurrentPosition(
          (position: GeolocationPosition) => {
            updateLocation({
              lat: position.coords.latitude,
              lng: position.coords.longitude,
            });
          },
          () => {}
        );
      }, 10000);
      
      return () => clearInterval(locationInterval);
    } else {
      getLocationFromIP().then(ipLoc => { if (ipLoc) updateLocation(ipLoc); });
    }
  }, [isLoggedIn, loginEmail, isOnline, apiClient, onLocationUpdate]);

  // Send online/offline status
  useEffect(() => {
    if (!isLoggedIn || !loginEmail || !driverLocation) return;
    apiClient.post('/drivers/update-status/', {
      email: loginEmail,
      is_online: isOnline,
      latitude: driverLocation.lat,
      longitude: driverLocation.lng,
    }).catch((error: any) => {
      console.error('Error updating driver status:', error);
    });
  }, [isOnline, isLoggedIn, loginEmail, driverLocation, apiClient]);

  return {
    // State
    isLoggedIn,
    loginEmail,
    isOnline,
    rideRequests,
    activeRide,
    activeRideStatus,
    activeRideId,
    driverLocation,
    searchRadius,
    subscriptionStatus,
    
    // Setters
    setIsOnline,
    setSearchRadius,
    setLoginEmail,
    
    // Actions
    handleLogin,
    handleLogout,
    handleAcceptRide,
    handleUpdateRideStatus,
  };
}
