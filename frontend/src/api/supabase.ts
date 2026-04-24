import { createClient } from '@supabase/supabase-js';
import { CONFIG } from '../config/env.config';

/**
 * Standard Practice: Use validated config from a central source.
 * This prevents app crashes while maintaining visibility of missing features.
 */
export const isConfigured = CONFIG.SUPABASE.isConfigured;

if (!isConfigured && CONFIG.IS_DEV) {
  console.warn('⚠️ Supabase features are disabled due to missing configuration.');
}

export const supabase = createClient(
  CONFIG.SUPABASE.URL || 'https://placeholder.supabase.co',
  CONFIG.SUPABASE.ANON_KEY || 'placeholder-key'
);
