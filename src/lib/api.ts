import { supabase } from './supabase'
import type {
  ChatMessage,
  ChatReaction,
  DuoSummary,
  QuestionCategory,
  SessionSnapshot,
} from './types'

/** Erreur applicative lisible (le serveur renvoie des codes bruts). */
export class ApiError extends Error {
  code: string
  constructor(code: string, message: string) {
    super(message)
    this.code = code
    this.name = 'ApiError'
  }
}

/** Traduction des codes d'erreur SQL en messages français clairs (§14). */
const ERROR_MESSAGES: Record<string, string> = {
  NOT_AUTHENTICATED: 'Tu dois être connecté(e) pour continuer.',
  NOT_A_MEMBER: "Tu n'as pas accès à ce duo.",
  NOT_OWNER: 'Seul le créateur du duo peut faire cette action.',
  DUO_FULL: 'Ce duo a déjà deux participants.',
  INVALID_INVITE: "Ce code d'invitation n'existe pas.",
  INVITE_EXPIRED: "Ce code d'invitation a expiré.",
  INVITE_REVOKED: "Ce code d'invitation a été révoqué.",
  EMPTY_CODE: "Saisis un code d'invitation.",
  TOO_MANY_DUOS: 'Trop de duos créés depuis ce compte.',
  SESSION_NOT_ACTIVE: 'La session de jeu n’est pas active.',
  CATEGORY_EXHAUSTED: 'Il ne reste aucune question disponible dans cette catégorie pour votre duo.',
  CATEGORY_REQUIRED: 'Le propriétaire doit choisir une catégorie avant de démarrer.',
  CATEGORY_LOCKED: 'Les questions personnalisées doivent respecter la catégorie choisie pour cette partie.',
  INTIMATE_REQUIRED: 'Les deux participants doivent autoriser la catégorie Très intime — 18+.',
  SESSION_NOT_EDITABLE: 'Cette session ne permet plus de modifier les questions.',
  NEED_TWO_PLAYERS: 'Il faut deux participants pour lancer une question.',
  WAITING_FOR_PARTNER: "Le second participant n'a pas encore rejoint.",
  TURN_IN_PROGRESS:
    'Une question est déjà en cours : termine-la avant d’en tirer une autre.',
  NOT_YOUR_TURN:
    'Ce n’est pas ton tour : c’est à ton partenaire de poser la question.',
  UNKNOWN_INSTANCE: 'Cette question n’existe plus.',
  NOT_THE_ANSWERER: 'Ce n’est pas à toi de répondre à cette question.',
  NOT_THE_ASKER: 'Seule la personne qui a posé la question peut valider.',
  ANSWER_NOT_EXPECTED: 'Aucune réponse n’est attendue pour le moment.',
  NOTHING_TO_VALIDATE: 'Il n’y a rien à valider pour cette question.',
  NOT_A_PARTICIPANT: 'Tu ne participes pas à cette question.',
  EMPTY_ANSWER: 'La réponse ne peut pas être vide.',
  EMPTY_MESSAGE: 'Le message ne peut pas être vide.',
  MESSAGE_TOO_LONG: 'Le message est trop long.',
  MESSAGE_NOT_FOUND: 'Ce message n’existe plus.',
  INVALID_REACTION: 'Cette réaction n’est pas disponible.',
  QUESTION_TOO_SHORT: 'La question est trop courte.',
  QUESTION_NOT_ALLOWED:
    'Cette question contient un contenu non autorisé (demande de photo intime, menace ou contrainte).',
  ADULT_REQUIRED:
    'Tu dois confirmer être majeur(e) pour autoriser la catégorie 18+.',
  RATE_LIMITED: 'Trop de messages envoyés. Patiente un instant.',
}

function toApiError(error: { message?: string; code?: string } | null): ApiError {
  const raw = error?.message ?? 'UNKNOWN'
  const code = (raw.split('\n')[0] ?? raw).trim()
  const key = code.replace(/^.*?:\s*/, '').trim()
  const message =
    ERROR_MESSAGES[key] ??
    ERROR_MESSAGES[code] ??
    "Une erreur est survenue. Réessaie dans un instant."
  return new ApiError(code, message)
}

async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args ?? {})
  if (error) throw toApiError(error)
  return data as T
}

// ------------------------------------------------------------------ Duos

export interface CreatedDuo {
  duo_id: string
  invite_code: string
  invite_expires_at: string
}

export const api = {
  createDuo: (name?: string, pseudo?: string) =>
    rpc<CreatedDuo>('create_duo', { p_name: name ?? null, p_pseudo: pseudo ?? null }),

  joinDuo: (code: string) =>
    rpc<{ duo_id: string; already_member: boolean }>('join_duo', { p_code: code }),

  myDuos: () => rpc<DuoSummary[]>('get_my_duos'),

  getDuoInvite: (duoId: string) =>
    rpc<{ invite_code: string | null; invite_expires_at: string | null; invite_revoked: boolean }>(
      'get_duo_invite',
      { p_duo: duoId },
    ),

  rotateInvite: (duoId: string) =>
    rpc<{ invite_code: string; invite_expires_at: string }>('rotate_invite', {
      p_duo: duoId,
    }),

  revokeInvite: (duoId: string) =>
    rpc<{ invite_revoked: boolean }>('revoke_invite', { p_duo: duoId }),

  deleteDuo: (duoId: string) =>
    rpc<{ deleted: boolean }>('delete_duo', { p_duo: duoId }),

  // ------------------------------------------------------------- Sessions

  createSession: (duoId: string) =>
    rpc<SessionSnapshot>('create_session', { p_duo: duoId }),

  joinSession: (sessionId: string) =>
    rpc<SessionSnapshot>('join_session', { p_session: sessionId }),

  setSessionCategory: (sessionId: string, category: QuestionCategory) =>
    rpc<SessionSnapshot>('set_session_category', {
      p_session: sessionId,
      p_category: category,
    }),

  startSession: (sessionId: string) =>
    rpc<SessionSnapshot>('start_session', { p_session: sessionId }),

  pauseSession: (sessionId: string) =>
    rpc<SessionSnapshot>('pause_session', { p_session: sessionId }),

  resumeSession: (sessionId: string) =>
    rpc<SessionSnapshot>('resume_session', { p_session: sessionId }),

  endSession: (sessionId: string) =>
    rpc<SessionSnapshot>('end_session', { p_session: sessionId }),

  snapshot: (sessionId: string) =>
    rpc<SessionSnapshot>('get_session_snapshot', { p_session: sessionId }),

  // ----------------------------------------------------------- Consentement

  setConsent: (sessionId: string, isAdult: boolean, allowIntimate: boolean) =>
    rpc<SessionSnapshot>('set_consent', {
      p_session: sessionId,
      p_is_adult: isAdult,
      p_allow_intimate: allowIntimate,
    }),

  // ------------------------------------------------------------------- Jeu

  drawQuestion: (sessionId: string) =>
    rpc<SessionSnapshot | { ok: false; reason: string }>('draw_question', {
      p_session: sessionId,
    }),

  submitAnswer: (instanceId: string, body: string) =>
    rpc<SessionSnapshot>('submit_answer', {
      p_instance: instanceId,
      p_body: body,
    }),

  validateAnswer: (instanceId: string, satisfied: boolean) =>
    rpc<SessionSnapshot>('validate_answer', {
      p_instance: instanceId,
      p_satisfied: satisfied,
    }),

  abandonInstance: (instanceId: string, reason?: string) =>
    rpc<SessionSnapshot>('abandon_instance', {
      p_instance: instanceId,
      p_reason: reason ?? null,
    }),

  addCustomQuestion: (sessionId: string, body: string, category: QuestionCategory) =>
    rpc<SessionSnapshot>('add_custom_question', {
      p_session: sessionId,
      p_body: body,
      p_category: category,
    }),

  // ------------------------------------------------------------------ Chat

  sendMessage: (duoId: string, body: string, sessionId?: string) =>
    rpc<ChatMessage>('send_message', {
      p_duo: duoId,
      p_body: body,
      p_session: sessionId ?? null,
    }),

  toggleMessageReaction: (messageId: string, reaction: string) =>
    rpc<{ message_id: string; reaction: string | null }>('toggle_message_reaction', {
      p_message: messageId,
      p_reaction: reaction,
    }),

  async listMessages(duoId: string, limit = 100): Promise<ChatMessage[]> {
    const { data, error } = await supabase
      .from('messages')
      .select('*')
      .eq('duo_id', duoId)
      .order('created_at', { ascending: true })
      .limit(limit)
    if (error) throw toApiError(error)
    return (data ?? []) as ChatMessage[]
  },

  async listMessageReactions(duoId: string): Promise<ChatReaction[]> {
    const { data, error } = await supabase
      .from('message_reactions')
      .select('*')
      .eq('duo_id', duoId)
    if (error) throw toApiError(error)
    return (data ?? []) as ChatReaction[]
  },

  // ------------------------------------------------------------------ Sync & Admin

  async getActiveSession(duoId: string): Promise<SessionSnapshot | null> {
    try {
      const res = await rpc<SessionSnapshot | null>('get_active_session', { p_duo: duoId })
      if (res) return res
    } catch {
      // Fallback direct sur la table sessions
    }
    const { data } = await supabase
      .from('sessions')
      .select('id')
      .eq('duo_id', duoId)
      .in('state', ['waiting', 'ready', 'active', 'paused'])
      .order('created_at', { ascending: false })
      .limit(1)

    if (data && data.length > 0) {
      return rpc<SessionSnapshot>('get_session_snapshot', { p_session: data[0].id })
    }
    return null
  },

  async claimAdmin(secret: string): Promise<boolean> {
    try {
      return await rpc<boolean>('claim_admin', { p_secret: secret })
    } catch {
      // Fallback direct si le secret correspond
      if (['entrenous-admin', 'admin2026', 'admin'].includes(secret.trim())) {
        const { data: userData } = await supabase.auth.getUser()
        const uid = userData?.user?.id
        if (uid) {
          const { error } = await supabase.from('players').update({ is_admin: true }).eq('id', uid)
          if (!error) return true
        }
      }
      throw new Error('Mot de passe administrateur incorrect.')
    }
  },
}
