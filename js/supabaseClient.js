import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './config.js';

if (SUPABASE_URL.includes('YOUR-PROJECT') || SUPABASE_ANON_KEY.includes('YOUR-ANON-KEY')) {
  console.warn(
    '[EarthMotion] js/config.js still has placeholder Supabase credentials. ' +
    'Create a Supabase project and fill them in — see README.md.'
  );
}

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
