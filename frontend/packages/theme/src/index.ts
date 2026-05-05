/**
 * Shared design tokens and theme for EliteCar
 * Used by both web and mobile applications
 */

// Colors — matches the zinc/blue palette used across web and mobile
export const colors = {
  // Brand blues (Tailwind blue-*)
  blue50:  '#eff6ff',
  blue100: '#dbeafe',
  blue200: '#bfdbfe',
  blue300: '#93c5fd',
  blue400: '#60a5fa',
  blue500: '#3b82f6',
  blue600: '#2563eb',  // primaryBlue
  blue700: '#1d4ed8',
  blue800: '#1e40af',
  blue900: '#1e3a8a',  // darkBlue / header

  // Zinc neutrals (Tailwind zinc-*)
  zinc50:  '#fafafa',
  zinc100: '#f4f4f5',
  zinc200: '#e4e4e7',
  zinc300: '#d4d4d8',
  zinc400: '#a1a1aa',
  zinc500: '#71717a',
  zinc600: '#52525b',
  zinc700: '#3f3f46',
  zinc800: '#27272a',
  zinc900: '#18181b',

  // Greens
  green50:  '#f0fdf4',
  green100: '#dcfce7',
  green600: '#16a34a',
  green700: '#15803d',

  // Reds
  red50:  '#fef2f2',
  red500: '#ef4444',
  red600: '#dc2626',

  // Yellows
  yellow400: '#facc15',
  yellow500: '#eab308',

  // Base
  white: '#ffffff',
  black: '#000000',

  // Semantic aliases
  primary:     '#2563eb',  // blue-600
  primaryDark: '#1e3a8a',  // blue-900
  primaryLight:'#3b82f6',  // blue-500
  success:     '#16a34a',  // green-600
  error:       '#ef4444',  // red-500
  warning:     '#eab308',  // yellow-500

  // Backgrounds
  background:          '#ffffff',
  backgroundSecondary: '#fafafa',
  backgroundTertiary:  '#f4f4f5',

  // Text
  text:          '#27272a',  // zinc-800
  textSecondary: '#71717a',  // zinc-500
  textTertiary:  '#a1a1aa',  // zinc-400
  textInverse:   '#ffffff',

  // Borders
  border:     '#e4e4e7',  // zinc-200
  borderDark: '#d4d4d8',  // zinc-300
} as const;

// Typography
export const typography = {
  // Font families
  fontFamily: {
    regular: 'System',
    medium: 'System',
    bold: 'System',
    mono: 'monospace',
  },
  
  // Font sizes
  fontSize: {
    xs: 12,
    sm: 14,
    base: 16,
    lg: 18,
    xl: 20,
    '2xl': 24,
    '3xl': 30,
    '4xl': 36,
    '5xl': 48,
  },
  
  // Font weights
  fontWeight: {
    light: '300',
    regular: '400',
    medium: '500',
    semibold: '600',
    bold: '700',
  },
  
  // Line heights
  lineHeight: {
    tight: 1.2,
    normal: 1.5,
    relaxed: 1.75,
  },
} as const;

// Spacing
export const spacing = {
  xs: 4,
  sm: 8,
  md: 16,
  lg: 24,
  xl: 32,
  '2xl': 40,
  '3xl': 48,
  '4xl': 64,
  '5xl': 80,
} as const;

// Border radius
export const borderRadius = {
  none: 0,
  sm: 4,
  md: 8,
  lg: 12,
  xl: 16,
  '2xl': 24,
  full: 9999,
} as const;

// Shadows (for web)
export const shadows = {
  sm: '0 1px 2px 0 rgba(0, 0, 0, 0.05)',
  base: '0 1px 3px 0 rgba(0, 0, 0, 0.1), 0 1px 2px 0 rgba(0, 0, 0, 0.06)',
  md: '0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06)',
  lg: '0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05)',
  xl: '0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04)',
  '2xl': '0 25px 50px -12px rgba(0, 0, 0, 0.25)',
} as const;

// Elevation (for mobile - React Native)
export const elevation = {
  sm: 2,
  base: 4,
  md: 6,
  lg: 8,
  xl: 12,
  '2xl': 16,
} as const;

// Breakpoints (for web)
export const breakpoints = {
  xs: 0,
  sm: 640,
  md: 768,
  lg: 1024,
  xl: 1280,
  '2xl': 1536,
} as const;

// Z-index layers
export const zIndex = {
  base: 0,
  dropdown: 10,
  sticky: 20,
  overlay: 30,
  modal: 40,
  popover: 50,
  tooltip: 60,
} as const;

// Animation durations (in ms)
export const duration = {
  fastest: 100,
  fast: 200,
  normal: 300,
  slow: 500,
  slowest: 800,
} as const;

// Common component styles
export const components = {
  button: {
    height: 44,
    paddingHorizontal: spacing.lg,
    borderRadius: borderRadius.md,
  },
  input: {
    height: 44,
    paddingHorizontal: spacing.md,
    borderRadius: borderRadius.md,
    borderWidth: 1,
  },
  card: {
    padding: spacing.lg,
    borderRadius: borderRadius.lg,
    backgroundColor: colors.white,
  },
} as const;

// Export theme object
export const theme = {
  colors,
  typography,
  spacing,
  borderRadius,
  shadows,
  elevation,
  breakpoints,
  zIndex,
  duration,
  components,
} as const;

export type Theme = typeof theme;
export default theme;
