import { NavLink } from 'react-router-dom'
import type { ReactNode } from 'react'

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
  /** Masque la navigation du bas (écrans plein écran comme le jeu). */
  hideNav?: boolean
}

export function Layout({ title, children, hideNav = false }: LayoutProps) {
  return (
    <div className="app-shell" style={hideNav ? { paddingBottom: 0 } : undefined}>
      <header className="topbar">
        <span className="topbar__brand">Entre Nous</span>
        {title ? <h2 className="topbar__title">{title}</h2> : <span className="spacer" />}
      </header>
      <main className="container">{children}</main>
      {!hideNav && <BottomNav />}
    </div>
  )
}
