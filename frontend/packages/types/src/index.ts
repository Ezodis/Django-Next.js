/**
 * Shared TypeScript type definitions for EliteCar
 * Used by both web and mobile applications
 */

// Ride-related types
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

// Coordinates type
export interface Coordinates {
  lat: number;
  lng: number;
}

// Ride search data for persistence
export interface RideSearchData {
  pickup: string;
  dropoff: string;
  passengerName: string;
  passengerPhone: string;
  selectedRide: string;
  paymentMethod: string;
  pickupCoordinates: Coordinates | null;
  dropoffCoordinates: Coordinates | null;
  timestamp: number;
}

// Driver login data
export interface DriverLoginData {
  email: string;
  timestamp: number;
}

// Active ride data for drivers
export interface ActiveRideData {
  id: string; // Frontend format: "ride-123"
  rideId: number; // Backend format: 123
  passengerName: string;
  pickupLocation: string;
  dropoffLocation: string;
  distance: string;
  estimatedFare: number;
  pickupCoords: Coordinates;
  dropoffCoords?: Coordinates;
  status: 'matched' | 'arriving' | 'passenger_onboard';
  timestamp: number;
}

// Passenger active ride data
export interface PassengerActiveRideData {
  rideId: number;
  status: 'requested' | 'matched' | 'arriving' | 'passenger_onboard';
  pickup: string;
  dropoff: string;
  pickupCoordinates: Coordinates | null;
  dropoffCoordinates: Coordinates | null;
  passengerName: string;
  passengerPhone: string;
  selectedRide: string;
  paymentMethod: string;
  timestamp: number;
}

// API Response types
export interface ApiResponse<T = any> {
  data?: T;
  error?: string;
  message?: string;
}

// User types
export interface User {
  id: number;
  email: string;
  name: string;
  phone?: string;
}

// Driver types
export interface Driver extends User {
  vehicleInfo?: VehicleInfo;
  rating?: number;
  totalRides?: number;
}

// Vehicle info
export interface VehicleInfo {
  make: string;
  model: string;
  year: number;
  color: string;
  licensePlate: string;
}

// Payment method types
export interface PaymentMethod {
  id: string;
  type: 'card' | 'cash';
  last4?: string;
  brand?: string;
  default?: boolean;
}

// Subscription types
export interface Subscription {
  id: string;
  type: string;
  status: 'active' | 'inactive' | 'cancelled';
  startDate: string;
  endDate?: string;
}

// Map-related types
export interface MapLocation {
  coordinates: Coordinates;
  address: string;
}

// Navigation types for mobile
export type RootStackParamList = {
  Home: undefined;
  RideRequest: undefined;
  Driver: undefined;
  Profile: undefined;
  RideHistory: undefined;
  Settings: undefined;
};

// Ride types enum
export type RideType = 'elitecar' | 'premium' | 'economy';

// Ride status enum
export type RideStatus = 
  | 'requested' 
  | 'matched' 
  | 'arriving' 
  | 'passenger_onboard' 
  | 'completed' 
  | 'cancelled';
