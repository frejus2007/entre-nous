import { NavLink, useNavigate } from 'react-router-dom'
import type { ReactNode } from 'react'
import { useAuth } from '../context/AuthContext'

const NAV = [
  { to: '/', label: 'Accueil', icon: '🏠', end: true },
  { to: '/jeu', label: 'Jeu', icon: '💬', end: false },
  { to: '/chat', label: 'Chat', icon: '✉️', end: false },
  { to: '/confidentialite', label: 'Confidentialité', icon: '🔒', end: false },
]

export function BottomNav() {
  return (
    <nav className="bottom-nav" aria-label="Navigation principale">
      {NAV.map((item) => (
        <NavLink
          key={item.to}
          to={item.to}
          end={item.end}
          className="bottom-nav__item"
        >
          <span className="bottom-nav__icon" aria-hidden="true">
            {item.icon}
          </span>
          {item.label}
        </NavLink>
      ))}
    </nav>
  )
}

interface LayoutProps {
  title?: string
  children: ReactNode
  /** Affiche le bouton de déconnexion dans la barre du haut. */
  showSignOut?: boolean
  /** Masque la navigation du bas (écrans plein écran comme le jeu). */
  hideNav?: boolean
}

export function Layout({
  title,
  children,
  showSignOut = true,
  hideNav = false,
}: LayoutProps) {
  const { signOut } = useAuth()
  const navigate = useNavigate()

  return (
    <div className="app-shell" style={hideNav ? { paddingBottom: 0 } : undefined}>
      <header className="topbar">
        <span className="topbar__brand">Entre Nous</span>
        {title ? <h2 className="topbar__title">{title}</h2> : <span className="spacer" />}
        {showSignOut && (
          <button
            type="button"
            className="link-btn"
            onClick={async () => {
              await signOut()
              navigate('/')
            }}
          >
            Quitter
          </button>
        )}
      </header>
      <main className="container">{children}</main>
      {!hideNav && <BottomNav />}
    </div>
  )
}
