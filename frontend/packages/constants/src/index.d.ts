/**
 * Shared constants and configuration for EliteCar
 * Used by both web and mobile applications
 */
export declare const STORAGE_KEYS: {
    readonly RIDE_SEARCH_DATA: "elitecar_search_data";
    readonly SESSION_ID: "elitecar_session_id";
    readonly DRIVER_LOGIN: "elitecar_driver_login";
    readonly DRIVER_RADIUS: "elitecar_driver_radius";
    readonly DRIVER_ACTIVE_RIDE: "elitecar_driver_active_ride";
    readonly PASSENGER_ACTIVE_RIDE: "elitecar_passenger_active_ride";
};
export declare const TIME_CONSTANTS: {
    readonly DRIVER_LOGIN_EXPIRY_MS: number;
    readonly PASSENGER_RIDE_EXPIRY_MS: number;
    readonly RIDE_DATA_EXPIRY_MS: number;
    readonly DRIVER_ACTIVE_RIDE_EXPIRY_MS: number;
};
export declare const DISTANCE_CONSTANTS: {
    readonly MAX_DRIVER_RADIUS_KM: 50;
    readonly DEFAULT_DRIVER_RADIUS_KM: 10;
};
export declare const API_ENDPOINTS: {
    readonly CSRF: "/csrf/";
    readonly RIDES: "/rides/";
    readonly DRIVERS: "/drivers/";
    readonly USERS: "/users/";
    readonly PAYMENTS: "/payments/";
    readonly SUBSCRIPTIONS: "/subscriptions/";
};
export declare const RIDE_TYPES: {
    readonly ELITERIDE: "elitecar";
    readonly PREMIUM: "premium";
    readonly ECONOMY: "economy";
};
export declare const RIDE_STATUS: {
    readonly REQUESTED: "requested";
    readonly MATCHED: "matched";
    readonly ARRIVING: "arriving";
    readonly PASSENGER_ONBOARD: "passenger_onboard";
    readonly COMPLETED: "completed";
    readonly CANCELLED: "cancelled";
};
export declare const DEFAULTS: {
    readonly SELECTED_RIDE: "elitecar";
    readonly PAYMENT_METHOD: "visa-1234";
};
export declare const APP_CONFIG: {
    readonly API_URL: string;
    readonly STRIPE_PUBLISHABLE_KEY: string;
    readonly GOOGLE_MAPS_API_KEY: string;
};
export declare const ERROR_MESSAGES: {
    readonly NETWORK_ERROR: "Network error. Please check your connection and try again.";
    readonly AUTH_ERROR: "Authentication failed. Please log in again.";
    readonly VALIDATION_ERROR: "Please check your input and try again.";
    readonly UNKNOWN_ERROR: "An unexpected error occurred. Please try again.";
};
//# sourceMappingURL=index.d.ts.map