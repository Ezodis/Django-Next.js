/**
 * Platform-agnostic storage interface for EliteCar
 * Works with localStorage (web) or AsyncStorage (React Native)
 */

import {
  RideSearchData,
  DriverLoginData,
  ActiveRideData,
  PassengerActiveRideData,
} from '@elitecar/types';
import { STORAGE_KEYS, TIME_CONSTANTS, DISTANCE_CONSTANTS, DEFAULTS } from '@elitecar/constants';

/**
 * Storage interface that can be implemented for different platforms
 */
export interface IStorage {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

/**
 * Web storage implementation using localStorage
 */
export class WebStorage implements IStorage {
  async getItem(key: string): Promise<string | null> {
    if (typeof window === 'undefined') return null;
    return localStorage.getItem(key);
  }

  async setItem(key: string, value: string): Promise<void> {
    if (typeof window === 'undefined') return;
    localStorage.setItem(key, value);
  }

  async removeItem(key: string): Promise<void> {
    if (typeof window === 'undefined') return;
    localStorage.removeItem(key);
  }
}

/**
 * Storage manager that provides high-level storage operations
 */
export class StorageManager {
  private storage: IStorage;

  constructor(storage: IStorage) {
    this.storage = storage;
  }

  // Session ID management
  async generateSessionId(): Promise<string> {
    return `session_${Date.now()}_${Math.random().toString(36).substring(2, 11)}`;
  }

  async getSessionId(): Promise<string> {
    let sessionId = await this.storage.getItem(STORAGE_KEYS.SESSION_ID);
    if (!sessionId) {
      sessionId = await this.generateSessionId();
      await this.storage.setItem(STORAGE_KEYS.SESSION_ID, sessionId);
    }
    return sessionId;
  }

  // Ride search data management
  async saveRideSearchData(data: Partial<RideSearchData>): Promise<void> {
    try {
      const existingData = await this.getRideSearchData();
      const updatedData: RideSearchData = {
        ...existingData,
        ...data,
        timestamp: Date.now(),
      };
      await this.storage.setItem(STORAGE_KEYS.RIDE_SEARCH_DATA, JSON.stringify(updatedData));
    } catch (error) {
      console.error('Error saving ride search data:', error);
    }
  }

  async getRideSearchData(): Promise<RideSearchData> {
    try {
      const stored = await this.storage.getItem(STORAGE_KEYS.RIDE_SEARCH_DATA);
      if (stored) {
        const data = JSON.parse(stored);
        // Check if data is not too old
        if (data.timestamp && Date.now() - data.timestamp < TIME_CONSTANTS.RIDE_DATA_EXPIRY_MS) {
          return data;
        }
      }
    } catch (error) {
      console.error('Error retrieving ride search data:', error);
    }
    return this.getDefaultSearchData();
  }

  async clearRideSearchData(): Promise<void> {
    try {
      await this.storage.removeItem(STORAGE_KEYS.RIDE_SEARCH_DATA);
    } catch (error) {
      console.error('Error clearing ride search data:', error);
    }
  }

  private getDefaultSearchData(): RideSearchData {
    return {
      pickup: '',
      dropoff: '',
      passengerName: '',
      passengerPhone: '',
      selectedRide: DEFAULTS.SELECTED_RIDE,
      paymentMethod: DEFAULTS.PAYMENT_METHOD,
      pickupCoordinates: null,
      dropoffCoordinates: null,
      timestamp: Date.now(),
    };
  }

  // Driver login management
  async saveDriverLogin(email: string): Promise<void> {
    try {
      const loginData: DriverLoginData = {
        email,
        timestamp: Date.now(),
      };
      await this.storage.setItem(STORAGE_KEYS.DRIVER_LOGIN, JSON.stringify(loginData));
    } catch (error) {
      console.error('Error saving driver login:', error);
    }
  }

  async getDriverLogin(): Promise<DriverLoginData | null> {
    try {
      const stored = await this.storage.getItem(STORAGE_KEYS.DRIVER_LOGIN);
      if (stored) {
        const data = JSON.parse(stored);
        // Check if login is not expired
        if (data.timestamp && Date.now() - data.timestamp < TIME_CONSTANTS.DRIVER_LOGIN_EXPIRY_MS) {
          return data;
        }
        // Clear expired login
        await this.clearDriverLogin();
      }
    } catch (error) {
      console.error('Error retrieving driver login:', error);
    }
    return null;
  }

  async clearDriverLogin(): Promise<void> {
    try {
      await this.storage.removeItem(STORAGE_KEYS.DRIVER_LOGIN);
    } catch (error) {
      console.error('Error clearing driver login:', error);
    }
  }

  // Driver radius management
  async saveDriverRadius(radius: number): Promise<void> {
    try {
      await this.storage.setItem(STORAGE_KEYS.DRIVER_RADIUS, radius.toString());
    } catch (error) {
      console.error('Error saving driver radius:', error);
    }
  }

  async getDriverRadius(defaultRadius: number = DISTANCE_CONSTANTS.DEFAULT_DRIVER_RADIUS_KM): Promise<number> {
    try {
      const stored = await this.storage.getItem(STORAGE_KEYS.DRIVER_RADIUS);
      if (stored) {
        const radius = parseFloat(stored);
        if (!isNaN(radius) && radius > 0 && radius <= DISTANCE_CONSTANTS.MAX_DRIVER_RADIUS_KM) {
          return radius;
        }
      }
    } catch (error) {
      console.error('Error retrieving driver radius:', error);
    }
    return defaultRadius;
  }

  // Driver active ride management
  async saveDriverActiveRide(ride: ActiveRideData): Promise<void> {
    try {
      await this.storage.setItem(STORAGE_KEYS.DRIVER_ACTIVE_RIDE, JSON.stringify(ride));
    } catch (error) {
      console.error('Error saving driver active ride:', error);
    }
  }

  async getDriverActiveRide(): Promise<ActiveRideData | null> {
    try {
      const stored = await this.storage.getItem(STORAGE_KEYS.DRIVER_ACTIVE_RIDE);
      if (stored) {
        const data = JSON.parse(stored);
        
        // Validate data structure
        if (!data || typeof data !== 'object') {
          console.warn('Invalid active ride data structure, clearing');
          await this.clearDriverActiveRide();
          return null;
        }
        
        // Check required fields
        if (!data.id || !data.rideId || !data.timestamp) {
          console.warn('Missing required fields in active ride data, clearing');
          await this.clearDriverActiveRide();
          return null;
        }
        
        // Check if ride data is not too old
        if (typeof data.timestamp === 'number' && 
            Date.now() - data.timestamp < TIME_CONSTANTS.DRIVER_ACTIVE_RIDE_EXPIRY_MS) {
          return data as ActiveRideData;
        }
        
        // Clear expired ride data
        console.log('Active ride data expired, clearing');
        await this.clearDriverActiveRide();
      }
    } catch (error) {
      console.error('Error retrieving driver active ride:', error);
      await this.clearDriverActiveRide();
    }
    return null;
  }

  async clearDriverActiveRide(): Promise<void> {
    try {
      await this.storage.removeItem(STORAGE_KEYS.DRIVER_ACTIVE_RIDE);
    } catch (error) {
      console.error('Error clearing driver active ride:', error);
    }
  }

  // Passenger active ride management
  async savePassengerActiveRide(ride: PassengerActiveRideData): Promise<void> {
    try {
      await this.storage.setItem(STORAGE_KEYS.PASSENGER_ACTIVE_RIDE, JSON.stringify(ride));
    } catch (error) {
      console.error('Error saving passenger active ride:', error);
    }
  }

  async getPassengerActiveRide(): Promise<PassengerActiveRideData | null> {
    try {
      const stored = await this.storage.getItem(STORAGE_KEYS.PASSENGER_ACTIVE_RIDE);
      if (stored) {
        const data = JSON.parse(stored);
        
        // Validate data structure
        if (!data || typeof data !== 'object') {
          console.warn('Invalid passenger active ride data structure, clearing');
          await this.clearPassengerActiveRide();
          return null;
        }
        
        // Check required fields
        if (!data.rideId || !data.timestamp) {
          console.warn('Missing required fields in passenger active ride data, clearing');
          await this.clearPassengerActiveRide();
          return null;
        }
        
        // Check if ride data is not too old
        if (typeof data.timestamp === 'number' && 
            Date.now() - data.timestamp < TIME_CONSTANTS.PASSENGER_RIDE_EXPIRY_MS) {
          return data as PassengerActiveRideData;
        }
        
        // Clear expired ride data
        console.log('Passenger active ride data expired, clearing');
        await this.clearPassengerActiveRide();
      }
    } catch (error) {
      console.error('Error retrieving passenger active ride:', error);
      await this.clearPassengerActiveRide();
    }
    return null;
  }

  async clearPassengerActiveRide(): Promise<void> {
    try {
      await this.storage.removeItem(STORAGE_KEYS.PASSENGER_ACTIVE_RIDE);
    } catch (error) {
      console.error('Error clearing passenger active ride:', error);
    }
  }
}

// Export a default web storage instance for convenience
export const webStorage = new WebStorage();
export const storageManager = new StorageManager(webStorage);
