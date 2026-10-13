import type { QuestionCategory } from './types'

/** Libellés et description des 7 catégories (§5). */
export const CATEGORY_LABELS: Record<QuestionCategory, string> = {
  brise_glace: 'Brise-glace',
  personnalite: 'Personnalité et habitudes',
  amour: 'Amour et séduction',
  secrets: 'Secrets et confidences',
  pimente: 'Pimenté',
  tres_intime: 'Très intime — 18+',
  avenir: 'Avenir et relations',
}

export const CATEGORY_ORDER: QuestionCategory[] = [
  'brise_glace',
  'personnalite',
  'amour',
  'secrets',
  'pimente',
  'tres_intime',
  'avenir',
]

/** Poids initiaux (§6.1) — purement indicatifs côté client (le serveur décide). */
export const CATEGORY_WEIGHTS: Record<QuestionCategory, number> = {
  tres_intime: 50,
  pimente: 25,
  amour: 10,
  secrets: 5,
  personnalite: 5,
  brise_glace: 3,
  avenir: 2,
}

export const CATEGORY_DESCRIPTIONS: Record<QuestionCategory, string> = {
  brise_glace: 'Questions simples pour commencer à se découvrir.',
  personnalite: 'Caractère, goûts, routines et habitudes.',
  amour: 'Attirance, affection et attentes romantiques.',
  secrets: 'Souvenirs, confidences et expériences personnelles.',
  pimente: 'Questions plus audacieuses.',
  tres_intime: 'Questions sexuelles ou très intimes, réservées aux adultes consentants.',
  avenir: 'Attentes, limites, projets et vision du couple.',
}

export const SESSION_STATE_LABELS: Record<string, string> = {
  waiting: 'En attente du second participant',
  ready: 'Prêt à démarrer',
  active: 'En cours',
  paused: 'En pause',
  finished: 'Terminée',
  expired: 'Expirée',
}
