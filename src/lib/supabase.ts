import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

/**
 * true si le projet Supabase est configuré.
 * Sans configuration, l'application affiche un écran de mise en route au lieu
 * de planter silencieusement.
 */
export const isSupabaseConfigured =
  Boolean(url) &&
  Boolean(anonKey) &&
  !url.includes('xxxxxxxx') &&
  anonKey.length > 20

export const supabase = createClient(
  isSupabaseConfigured ? url : 'http://localhost:54321',
  isSupabaseConfigured ? anonKey : 'public-anon-key-placeholder',
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      // Identité persistante et récupérable (§4.3).
      storageKey: 'entre-nous-auth',
    },
  },
)
