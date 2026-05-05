/**
 * Shared TypeScript type definitions for EliteCar
 * Used by both web and mobile applications
 */
export interface RideRequest {
    id: string;
    passengerName: string;
    pickupLocation: string;
    dropoffLocation: string;
    distance: string;
    estimatedFare: number;
    pickupCoords: {
        lat: number;
        lng: number;
    };
    dropoffCoords?: {
        lat: number;
        lng: number;
    };
}
export interface Coordinates {
    lat: number;
    lng: number;
}
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
export interface DriverLoginData {
    email: string;
    timestamp: number;
}
export interface ActiveRideData {
    id: string;
    rideId: number;
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
export interface ApiResponse<T = any> {
    data?: T;
    error?: string;
    message?: string;
}
export interface User {
    id: number;
    email: string;
    name: string;
    phone?: string;
}
export interface Driver extends User {
    vehicleInfo?: VehicleInfo;
    rating?: number;
    totalRides?: number;
}
export interface VehicleInfo {
    make: string;
    model: string;
    year: number;
    color: string;
    licensePlate: string;
}
export interface PaymentMethod {
    id: string;
    type: 'card' | 'cash';
    last4?: string;
    brand?: string;
    default?: boolean;
}
export interface Subscription {
    id: string;
    type: string;
    status: 'active' | 'inactive' | 'cancelled';
    startDate: string;
    endDate?: string;
}
export interface MapLocation {
    coordinates: Coordinates;
    address: string;
}
export type RootStackParamList = {
    Home: undefined;
    RideRequest: undefined;
    Driver: undefined;
    Profile: undefined;
    RideHistory: undefined;
    Settings: undefined;
};
export type RideType = 'elitecar' | 'premium' | 'economy';
export type RideStatus = 'requested' | 'matched' | 'arriving' | 'passenger_onboard' | 'completed' | 'cancelled';
//# sourceMappingURL=index.d.ts.map