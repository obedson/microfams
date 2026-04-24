/**
 * Centralized Configuration Manager
 * Following Industry Standard: Single source of truth for all environment variables.
 */

const getEnv = (key: string, required = true): string => {
  const value = process.env[key];

  if (!value && required) {
    if (process.env.NODE_ENV === 'development') {
      // In development, we want to be loud so the developer fixes the .env
      console.error(`❌ CRITICAL CONFIG ERROR: Environment variable ${key} is missing.`);
    }
    return '';
  }

  return value || '';
};

export const CONFIG = {
  API_URL: getEnv('REACT_APP_API_URL', true),
  SUPABASE: {
    URL: getEnv('REACT_APP_SUPABASE_URL', false), // Set to false if we want the app to stay alive
    ANON_KEY: getEnv('REACT_APP_SUPABASE_ANON_KEY', false),
    isConfigured: Boolean(process.env.REACT_APP_SUPABASE_URL && process.env.REACT_APP_SUPABASE_ANON_KEY)
  },
  IS_DEV: process.env.NODE_ENV === 'development',
};
