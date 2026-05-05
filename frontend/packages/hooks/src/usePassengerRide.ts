import { useState, useEffect, useCallback, useRef } from 'react';

export type BookingStep = 'location' | 'ride' | 'confirm' | 'schedule' | 'matching' | 'driver' | 'rating';
export type RideStatus = 'pickup' | 'in_progress' | 'arriving';
export type BackendRideStatus = 'requested' | 'matched' | 'arriving' | 'passenger_onboard' | 'completed' | 'cancelled';

export interface Coordinates {
  lat: number;
  lng: number;
}

export interface DriverInfo {
  name: string;
  rating: number;
  trips: number;
  car: {
    make: string;
    model: string;
    color: string;
    plate: string;
  };
  eta: number;
  photo?: string;
  location?: Coordinates | null;
}

export interface UsePassengerRideOptions {
  apiClient: any;
  storage: any;
  onLocationUpdate?: (location: Coordinates) => void;
}

export function usePassengerRide({ apiClient, storage, onLocationUpdate }: UsePassengerRideOptions) {
  const [step, setStep] = useState<BookingStep>('location');
  const [pickup, setPickup] = useState('');
  const [dropoff, setDropoff] = useState('');
  const [passengerName, setPassengerName] = useState('');
  const [passengerPhone, setPassengerPhone] = useState('');
  const [selectedRide, setSelectedRide] = useState('elitecar');
  const [paymentMethod, setPaymentMethod] = useState('visa-1234');
  const [pickupCoordinates, setPickupCoordinates] = useState<Coordinates | null>(null);
  const [dropoffCoordinates, setDropoffCoordinates] = useState<Coordinates | null>(null);
  const [rideStatus, setRideStatus] = useState<RideStatus>('pickup');
  const [progress, setProgress] = useState(0);
  const [currentRideId, setCurrentRideId] = useState<number | null>(null);
  const [backendRideStatus, setBackendRideStatus] = useState<BackendRideStatus>('requested');
  const [assignedDriver, setAssignedDriver] = useState<DriverInfo | null>(null);
  const [calculatedPrice, setCalculatedPrice] = useState<number | null>(null);
  const [nearbyDriversCount, setNearbyDriversCount] = useState<number>(0);
  const [preferredTrips, setPreferredTrips] = useState<any[]>([]);
  const [isLoadingPreferredTrips, setIsLoadingPreferredTrips] = useState(false);
  const [selectedPreferredTrip, setSelectedPreferredTrip] = useState<any>(null);
  
  const sessionId = useRef<string>('');

  // Initialize session ID
  useEffect(() => {
    sessionId.current = storage.getSessionId();
  }, [storage]);

  // Geocode address helper
  const geocodeAddress = useCallback(async (address: string): Promise<Coordinates | null> => {
    try {
      const response = await fetch(
        `https://nominatim.openstreetmap.org/search?format=json&q=${encodeURIComponent(address)}&limit=1`,
        { headers: { 'User-Agent': 'EliteCar/1.0' } }
      );
      
      if (response.ok) {
        const data = await response.json() as Array<{ lat: string; lon: string }>;
        if (data && data.length > 0) {
          return {
            lat: parseFloat(data[0].lat),
            lng: parseFloat(data[0].lon)
          };
        }
      }
    } catch (error) {
      console.error('Error geocoding address:', error);
    }
    return null;
  }, []);

  // Search for rides
  const handleSearchRides = useCallback(async () => {
    if (pickup && dropoff) {
      setStep('ride');
      
      if (pickupCoordinates && dropoffCoordinates) {
        setIsLoadingPreferredTrips(true);
        try {
          const response = await apiClient.getRaw(
            `/rides/preferred-trips/search/?pickup_lat=${pickupCoordinates.lat}&pickup_lng=${pickupCoordinates.lng}&dropoff_lat=${dropoffCoordinates.lat}&dropoff_lng=${dropoffCoordinates.lng}`
          );
          
          if (response.ok) {
            const data = await response.json();
            setPreferredTrips(data.trips || []);
          }
        } catch (error) {
          console.error('Error fetching preferred trips:', error);
        } finally {
          setIsLoadingPreferredTrips(false);
        }
      }
    }
  }, [pickup, dropoff, pickupCoordinates, dropoffCoordinates, apiClient]);

  // Request ride
  const handleRequestRide = useCallback(async () => {
    setStep('matching');
    setAssignedDriver(null);
    
    let finalPickupCoords = pickupCoordinates;
    let finalDropoffCoords = dropoffCoordinates;
    
    if (!finalPickupCoords && pickup) {
      finalPickupCoords = await geocodeAddress(pickup);
      if (finalPickupCoords) setPickupCoordinates(finalPickupCoords);
    }
    
    if (!finalDropoffCoords && dropoff) {
      finalDropoffCoords = await geocodeAddress(dropoff);
      if (finalDropoffCoords) setDropoffCoordinates(finalDropoffCoords);
    }
    
    if (!finalPickupCoords || !finalDropoffCoords) {
      throw new Error('Missing coordinates');
    }
    
    try {
      const response = await apiClient.post('/rides/request/', {
        session_id: sessionId.current,
        pickup_location: pickup,
        dropoff_location: dropoff,
        pickup_lat: finalPickupCoords.lat,
        pickup_lng: finalPickupCoords.lng,
        dropoff_lat: finalDropoffCoords.lat,
        dropoff_lng: finalDropoffCoords.lng,
        passenger_name: passengerName,
        passenger_phone: passengerPhone,
        ride_type: selectedRide,
        payment_method: paymentMethod,
      });
      
      const data = await response.json();
      
      if (response.ok && data.ride_id) {
        setCurrentRideId(data.ride_id);
        storage.savePassengerActiveRide({
          rideId: data.ride_id,
          status: 'requested',
          pickup,
          dropoff,
          pickupCoordinates: finalPickupCoords,
          dropoffCoordinates: finalDropoffCoords,
          passengerName,
          passengerPhone,
          selectedRide,
          paymentMethod,
          timestamp: Date.now()
        });
        return data.ride_id;
      } else {
        throw new Error(data.message || 'Failed to request ride');
      }
    } catch (error) {
      setStep('confirm');
      throw error;
    }
  }, [pickup, dropoff, pickupCoordinates, dropoffCoordinates, passengerName, passengerPhone, selectedRide, paymentMethod, apiClient, storage, geocodeAddress]);

  // Cancel ride
  const handleCancelRide = useCallback(async () => {
    if (currentRideId) {
      try {
        await apiClient.post(`/rides/${currentRideId}/cancel/`, {});
      } catch (error) {
        console.error('Error cancelling ride:', error);
      }
    }
    
    storage.clearPassengerActiveRide();
    setStep('location');
    setCurrentRideId(null);
    setAssignedDriver(null);
    setSelectedPreferredTrip(null);
  }, [currentRideId, apiClient, storage]);

  // Submit rating
  const handleSubmitRating = useCallback(async (rating: number, comment?: string) => {
    if (currentRideId) {
      try {
        await apiClient.post(`/rides/${currentRideId}/review/`, {
          rating,
          comment: comment || '',
        });
      } catch (error) {
        console.error('Error submitting review:', error);
      }
    }
    
    storage.clearPassengerActiveRide();
    setStep('location');
    setCurrentRideId(null);
    setAssignedDriver(null);
    setBackendRideStatus('requested');
    setDropoff('');
    setDropoffCoordinates(null);
    setProgress(0);
  }, [currentRideId, apiClient, storage]);

  return {
    // State
    step,
    pickup,
    dropoff,
    passengerName,
    passengerPhone,
    selectedRide,
    paymentMethod,
    pickupCoordinates,
    dropoffCoordinates,
    rideStatus,
    progress,
    currentRideId,
    backendRideStatus,
    assignedDriver,
    calculatedPrice,
    nearbyDriversCount,
    preferredTrips,
    isLoadingPreferredTrips,
    selectedPreferredTrip,
    
    // Setters
    setStep,
    setPickup,
    setDropoff,
    setPassengerName,
    setPassengerPhone,
    setSelectedRide,
    setPaymentMethod,
    setPickupCoordinates,
    setDropoffCoordinates,
    setAssignedDriver,
    setSelectedPreferredTrip,
    
    // Actions
    handleSearchRides,
    handleRequestRide,
    handleCancelRide,
    handleSubmitRating,
    geocodeAddress,
  };
}
