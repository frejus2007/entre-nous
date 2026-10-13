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
  /** Envoie un lien/code de connexion par e-mail (identité récupérable, §4.3). */
  signInWithEmail: (email: string) => Promise<void>
  verifyEmailCode: (email: string, token: string) => Promise<void>
  signOut: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next)
    })

    return () => sub.subscription.unsubscribe()
  }, [])

  const value = useMemo<AuthState>(
    () => ({
      session,
      loading,
      async signInWithEmail(email: string) {
        const { error } = await supabase.auth.signInWithOtp({
          email,
          options: { shouldCreateUser: true },
        })
        if (error) throw new Error(error.message)
      },
      async verifyEmailCode(email: string, token: string) {
        const { error } = await supabase.auth.verifyOtp({
          email,
          token,
          type: 'email',
        })
        if (error) throw new Error(error.message)
      },
      async signOut() {
        await supabase.auth.signOut()
      },
    }),
    [session, loading],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth doit être utilisé dans <AuthProvider>')
  return ctx
}
