import { createClient } from '@supabase/supabase-js';
import { backendConfiguration } from '../config/environment.js';

export const supabase = createClient(
  backendConfiguration.supabase.url,
  backendConfiguration.supabase.serviceKey,
);

export default supabase;
