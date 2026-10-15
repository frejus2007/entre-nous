// Les mêmes valeurs que les types énumérés SQL (0001_schema.sql).

export type QuestionCategory =
  | 'brise_glace'
  | 'personnalite'
  | 'amour'
  | 'secrets'
  | 'pimente'
  | 'tres_intime'
  | 'avenir'

export type SessionState =
  | 'waiting'
  | 'ready'
  | 'active'
  | 'paused'
  | 'finished'
  | 'expired'

export type TurnState =
  | 'awaiting_answer'
  | 'awaiting_validation'
  | 'clarification'
  | 'validated'
  | 'abandoned'

export type InstanceKind = 'catalog' | 'custom'

export interface Member {
  player_id: string
  pseudo: string
  role: 'owner' | 'member'
  present?: boolean
}

export interface Consent {
  player_id: string
  is_adult: boolean
  allow_intimate: boolean
}

export interface Answer {
  id: string
  author_id: string
  body: string
  is_clarification: boolean
  created_at: string
}

export interface Turn {
  instance_id: string
  category: QuestionCategory
  kind: InstanceKind
  question: string
  asker_id: string
  answerer_id: string
  state: TurnState
  answers: Answer[]
}

export interface SessionRow {
  id: string
  duo_id: string
  state: SessionState
  question_category: QuestionCategory | null
  started_at: string | null
  finished_at: string | null
  expires_at: string | null
  created_at: string
}

/** Réponse de get_session_snapshot() — l'état complet renvoyé par le serveur. */
export interface SessionSnapshot {
  session: SessionRow
  duo: { id: string; name: string | null }
  intimate_enabled: boolean
  /** Prochain poseur désigné (§10 : alternance « chacun son tour »). */
  next_asker_id: string | null
  members: Member[]
  consents: Consent[]
  turn: Turn | null
  remaining_by_category: Record<QuestionCategory, number>
}

export interface DuoSummary {
  id: string
  name: string | null
  created_at: string
  members: Member[]
  is_full: boolean
}

export interface ChatMessage {
  id: string
  duo_id: string
  session_id: string | null
  sender_id: string
  body: string
  created_at: string
}

export interface DrawResult {
  ok: boolean
  reason?: 'catalog_exhausted'
}
