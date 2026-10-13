import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from 'react'
import type { Session } from '@supabase/supabase-js'
import { supabase } from '../lib/supabase'

interface AuthState {
  session: Session | null
  loading: boolean
  /** Message d'erreur si l'identité locale n'a pas pu être créée. */
  error: string | null
  /**
   * Réinitialise l'identité de cet appareil (nouvel utilisateur anonyme).
   * Utile pour tester à deux sur un même navigateur.
   */
  resetIdentity: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

/**
 * Identité automatique et invisible : aucune connexion demandée.
 * L'application crée en arrière-plan un utilisateur Supabase anonyme, propre à
 * cet appareil/navigateur. Le serveur continue de vérifier `auth.uid()` et la
 * RLS (§16) : la sécurité n'est pas sacrifiée.
 */
export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let active = true

    async function ensureIdentity() {
      const existing = await supabase.auth.getSession()
      if (!active) return
      if (existing.data.session) {
        setSession(existing.data.session)
        setLoading(false)
        return
      }

      const { data, error: signInError } = await supabase.auth.signInAnonymously()
      if (!active) return
      if (signInError) {
        setError(signInError.message)
      } else {
        setSession(data.session)
      }
      setLoading(false)
    }

    void ensureIdentity()

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
    })

    return () => {
      active = false
      sub.subscription.unsubscribe()
    }
  }, [])

  const value = useMemo<AuthState>(
    () => ({
      session,
      loading,
      error,
      async resetIdentity() {
        await supabase.auth.signOut()
        const { data, error: signInError } = await supabase.auth.signInAnonymously()
        if (signInError) setError(signInError.message)
        else {
          setError(null)
          setSession(data.session)
        }
      },
    }),
    [session, loading, error],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth doit être utilisé dans <AuthProvider>')
  return ctx
}
