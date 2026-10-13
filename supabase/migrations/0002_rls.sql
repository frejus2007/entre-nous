-- =============================================================================
-- Entre Nous — 0002_rls.sql
-- Sécurité par ligne (Row Level Security).
-- Principe (§15, §16) : un duo est une frontière d'isolation stricte.
--   * un joueur ne voit que les duos dont il est membre ;
--   * un joueur ne voit que les sessions de ses duos ;
--   * réponses, messages et consentements ne sont lisibles que par les
--     deux participants autorisés du duo.
-- Toutes les écritures sensibles passent par des fonctions RPC (0003_rpc.sql) :
-- les policies d'écriture directe sont volontairement absentes.
-- =============================================================================

alter table public.players                  enable row level security;
alter table public.duos                      enable row level security;
alter table public.duo_members               enable row level security;
alter table public.sessions                  enable row level security;
alter table public.session_participants      enable row level security;
alter table public.questions                 enable row level security;
alter table public.duo_used_questions        enable row level security;
alter table public.session_custom_questions  enable row level security;
alter table public.session_consents          enable row level security;
alter table public.session_question_instances enable row level security;
alter table public.question_turns            enable row level security;
alter table public.question_answers          enable row level security;
alter table public.messages                  enable row level security;
alter table public.question_reports          enable row level security;

-- =============================================================================
-- Helpers d'autorisation
-- SECURITY DEFINER + search_path figé : ils évitent les récursions RLS
-- (ex. vérifier l'appartenance à un duo depuis une policy qui lit duo_members).
-- =============================================================================

create or replace function public.is_duo_member(p_duo uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.duo_members
    where duo_id = p_duo and player_id = auth.uid()
  );
$$;

create or replace function public.is_duo_owner(p_duo uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.duo_members
    where duo_id = p_duo and player_id = auth.uid() and role = 'owner'
  );
$$;

create or replace function public.is_session_member(p_session uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.sessions s
    join public.duo_members dm on dm.duo_id = s.duo_id
    where s.id = p_session and dm.player_id = auth.uid()
  );
$$;

revoke all on function public.is_duo_member(uuid) from public, anon;
revoke all on function public.is_duo_owner(uuid) from public, anon;
revoke all on function public.is_session_member(uuid) from public, anon;
grant execute on function public.is_duo_member(uuid) to authenticated;
grant execute on function public.is_duo_owner(uuid) to authenticated;
grant execute on function public.is_session_member(uuid) to authenticated;

-- =============================================================================
-- players
-- =============================================================================
create policy players_select_self
  on public.players for select
  to authenticated
  using (id = auth.uid());

-- Un joueur peut voir le pseudo des membres de ses duos (affichage du duo).
create policy players_select_co_members
  on public.players for select
  to authenticated
  using (
    exists (
      select 1
      from public.duo_members me
      join public.duo_members them on them.duo_id = me.duo_id
      where me.player_id = auth.uid() and them.player_id = players.id
    )
  );

create policy players_update_self
  on public.players for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- =============================================================================
-- duos — lisibles par les membres uniquement
-- =============================================================================
create policy duos_select_member
  on public.duos for select
  to authenticated
  using (public.is_duo_member(id));

-- =============================================================================
-- duo_members
-- =============================================================================
create policy duo_members_select_member
  on public.duo_members for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- sessions
-- =============================================================================
create policy sessions_select_member
  on public.sessions for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- session_participants
-- =============================================================================
create policy session_participants_select_member
  on public.session_participants for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- questions — catalogue global en lecture seule pour les utilisateurs connectés
-- =============================================================================
create policy questions_select_active
  on public.questions for select
  to authenticated
  using (is_active);

-- =============================================================================
-- duo_used_questions — historique privé du duo
-- =============================================================================
create policy duo_used_questions_select_member
  on public.duo_used_questions for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- session_custom_questions
-- =============================================================================
create policy custom_questions_select_member
  on public.session_custom_questions for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- session_consents — chaque participant voit les deux consentements de sa
-- session (nécessaire pour savoir si la catégorie 18+ est active), mais seul
-- le sien est modifiable, et uniquement via RPC.
-- =============================================================================
create policy consents_select_member
  on public.session_consents for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- session_question_instances
-- =============================================================================
create policy instances_select_member
  on public.session_question_instances for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- question_turns
-- =============================================================================
create policy turns_select_member
  on public.question_turns for select
  to authenticated
  using (public.is_session_member(session_id));

-- =============================================================================
-- question_answers
-- =============================================================================
create policy answers_select_member
  on public.question_answers for select
  to authenticated
  using (
    public.is_session_member(
      (select session_id from public.session_question_instances i where i.id = instance_id)
    )
  );

-- =============================================================================
-- messages — lisibles par les membres du duo
-- =============================================================================
create policy messages_select_member
  on public.messages for select
  to authenticated
  using (public.is_duo_member(duo_id));

-- =============================================================================
-- question_reports — visibles par leur auteur (les admins passeront par
-- la clé service_role, hors de portée du navigateur).
-- =============================================================================
create policy reports_select_author
  on public.question_reports for select
  to authenticated
  using (reported_by = auth.uid());
