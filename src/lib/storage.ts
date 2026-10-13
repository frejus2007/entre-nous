const DUO_KEY = 'entre-nous:current-duo'
const SESSION_KEY = 'entre-nous:current-session'

/** Mémorise localement le duo courant (confort d'usage, pas une autorisation). */
export const currentDuo = {
  get(): string | null {
    return localStorage.getItem(DUO_KEY)
  },
  set(id: string) {
    localStorage.setItem(DUO_KEY, id)
  },
  clear() {
    localStorage.removeItem(DUO_KEY)
  },
}

export const currentSession = {
  get(): string | null {
    return localStorage.getItem(SESSION_KEY)
  },
  set(id: string) {
    localStorage.setItem(SESSION_KEY, id)
  },
  clear() {
    localStorage.removeItem(SESSION_KEY)
  },
}
