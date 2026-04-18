// @elitecar/types
// Shared TypeScript types across web and mobile apps

export interface User {
  id: number;
  email: string;
  first_name: string;
  last_name: string;
  phone?: string;
  avatar?: string;
}

export interface Driver extends User {
  vehicle: Vehicle;
  rating: number;
  is_available: boolean;
}

export interface Vehicle {
  id: number;
  make: string;
  model: string;
  year: number;
  color: string;
  plate: string;
}

export interface Location {
  latitude: number;
  longitude: number;
  address?: string;
}

export interface Ride {
  id: number;
  passenger: User;
  driver?: Driver;
  pickup: Location;
  dropoff: Location;
  status: string;
  fare?: number;
  created_at: string;
  updated_at: string;
}

export interface ApiResponse<T> {
  data: T;
  message?: string;
  errors?: Record<string, string[]>;
}

export interface PaginatedResponse<T> {
  count: number;
  next: string | null;
  previous: string | null;
  results: T[];
}
