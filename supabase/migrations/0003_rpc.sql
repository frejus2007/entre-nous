-- =============================================================================
-- Entre Nous — 0003_rpc.sql
-- Fonctions serveur : LE SERVEUR EST LA SOURCE DE VÉRITÉ (§19).
-- Toutes les opérations sensibles (création de duo, tirage pondéré, réponses,
-- validation de satisfaction, consentement, chat) passent par ces fonctions.
-- Elles sont SECURITY DEFINER : elles contournent volontairement la RLS APRÈS
-- avoir vérifié elles-mêmes l'identité et les autorisations de l'appelant.
-- =============================================================================

-- =============================================================================
-- Garde-fou d'ordre d'application.
-- Ce fichier dépend des fonctions d'autorisation créées dans 0002_rls.sql.
-- Sans ce contrôle, l'erreur affichée serait « function public.is_duo_member
-- does not exist », difficile à diagnostiquer.
-- =============================================================================
do $$
begin
  if to_regprocedure('public.is_duo_member(uuid)') is null
     or to_regprocedure('public.is_duo_owner(uuid)') is null
     or to_regprocedure('public.is_session_member(uuid)') is null then
    raise exception 'MIGRATION_ORDER: applique d''abord 0002_rls.sql. Les fonctions d''autorisation (public.is_duo_member / is_duo_owner / is_session_member) sont absentes.';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Helpers internes
-- -----------------------------------------------------------------------------

create or replace function public.assert_duo_member(p_duo uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (
    select 1 from public.duo_members
    where duo_id = p_duo and player_id = auth.uid()
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;
end;
$$;

create or replace function public.assert_session_member(p_session uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not exists (
    select 1
    from public.sessions s
    join public.duo_members dm on dm.duo_id = s.duo_id
    where s.id = p_session and dm.player_id = auth.uid()
  ) then
    raise exception 'NOT_A_MEMBER';
  end if;
end;
$$;

-- Code d'invitation : 10 caractères base32 sans caractères ambigus.
create or replace function public.generate_invite_code()
returns text
language plpgsql
volatile
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  result text := '';
  i int;
begin
  for i in 1..10 loop
    result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
  end loop;
  return result;
end;
$$;

-- =============================================================================
-- Table des poids par catégorie (§6.1)
-- =============================================================================
create or replace function public.category_weight(p_category public.question_category)
returns numeric
language sql
immutable
as $$
  select case p_category
    when 'tres_intime'  then 50
    when 'pimente'      then 25
    when 'amour'        then 10
    when 'secrets'      then 5
    when 'personnalite' then 5
    when 'brise_glace'  then 3
    when 'avenir'       then 2
  end::numeric;
$$;

-- Alternance des tours (§10) : « chacun à son tour ».
-- Les rôles s'inversent à chaque tour : le tout premier poseur est le
-- créateur de la session, puis on alterne. On se base sur le nombre de tours
-- déjà entamés (parité), ce qui est déterministe et insensible à l'horloge.
create or replace function public.next_asker_id(p_session uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  with s as (
    select created_by, duo_id from public.sessions where id = p_session
  ),
  n as (
    select count(*)::int as c
    from public.session_question_instances
    where session_id = p_session
  )
  select case
    when (select c from n) % 2 = 0 then (select created_by from s)
    else (
      select dm.player_id
      from public.duo_members dm
      where dm.duo_id = (select duo_id from s)
        and dm.player_id <> (select created_by from s)
      order by dm.joined_at
      limit 1
    )
  end;
$$;

-- =============================================================================
-- DUOS
-- =============================================================================

-- Crée un duo privé et son code d'invitation. (§4.1)
create or replace function public.create_duo(
  p_name text default null,
  p_pseudo text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_duo_id  uuid;
  v_code    text;
  v_expires timestamptz := now() + interval '7 days';
  v_count   int;
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;

  -- Limite anti-abus raisonnable (§16.8).
  select count(*) into v_count from public.duos where created_by = v_uid;
  if v_count >= 20 then
    raise exception 'TOO_MANY_DUOS';
  end if;

  insert into public.players (id, pseudo)
  values (v_uid, coalesce(nullif(btrim(coalesce(p_pseudo, '')), ''), 'Anonyme'))
  on conflict (id) do update
    set pseudo = case
      when btrim(coalesce(excluded.pseudo, '')) <> '' and excluded.pseudo <> 'Anonyme'
      then excluded.pseudo else public.players.pseudo end;

  loop
    v_code := public.generate_invite_code();
    exit when not exists (select 1 from public.duos where invite_code = v_code);
  end loop;

  insert into public.duos (name, invite_code, invite_expires_at, created_by)
  values (nullif(btrim(coalesce(p_name, '')), ''), v_code, v_expires, v_uid)
  returning id into v_duo_id;

  insert into public.duo_members (duo_id, player_id, role)
  values (v_duo_id, v_uid, 'owner');

  return jsonb_build_object(
    'duo_id', v_duo_id,
    'invite_code', v_code,
    'invite_expires_at', v_expires
  );
end;
$$;

-- Rejoint un duo via son code d'invitation. (§4.2)
create or replace function public.join_duo(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_duo   public.duos;
  v_code  text := upper(btrim(coalesce(p_code, '')));
begin
  if v_uid is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if v_code = '' then raise exception 'EMPTY_CODE'; end if;

  select * into v_duo from public.duos where invite_code = v_code;
  if v_duo.id is null then raise exception 'INVALID_INVITE'; end if;
  if v_duo.invite_revoked then raise exception 'INVITE_REVOKED'; end if;
  if v_duo.invite_expires_at is not null and v_duo.invite_expires_at < now() then
    raise exception 'INVITE_EXPIRED';
  end if;

  insert into public.players (id, pseudo) values (v_uid, 'Anonyme')
  on conflict (id) do nothing;

  if exists (select 1 from public.duo_members where duo_id = v_duo.id and player_id = v_uid) then
    return jsonb_build_object('duo_id', v_duo.id, 'already_member', true);
  end if;

  insert into public.duo_members (duo_id, player_id, role)
  values (v_duo.id, v_uid, 'member');  -- le trigger refusera si le duo est plein

  return jsonb_build_object('duo_id', v_duo.id, 'already_member', false);
end;
$$;

-- Liste des duos du joueur, avec co-membres et état.
create or replace function public.get_my_duos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(d order by d ->> 'created_at' desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'id', du.id,
      'name', du.name,
      'created_at', du.created_at,
      'members', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'player_id', dm.player_id,
          'pseudo', coalesce(p.pseudo, 'Anonyme'),
          'role', dm.role
        ) order by dm.joined_at), '[]'::jsonb)
        from public.duo_members dm
        left join public.players p on p.id = dm.player_id
        where dm.duo_id = du.id
      ),
      'is_full', (select count(*) from public.duo_members m where m.duo_id = du.id) >= 2
    ) as d
    from public.duos du
    where public.is_duo_member(du.id)
  ) sub;
$$;

-- Affiche le code d'invitation courant aux membres du duo. (§4.2)
create or replace function public.get_duo_invite(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_duo public.duos;
begin
  perform public.assert_duo_member(p_duo);
  select * into v_duo from public.duos where id = p_duo;
  return jsonb_build_object(
    'invite_code', case when v_duo.invite_revoked then null else v_duo.invite_code end,
    'invite_expires_at', v_duo.invite_expires_at,
    'invite_revoked', v_duo.invite_revoked
  );
end;
$$;

-- Génère un nouveau code et le réactive (propriétaire uniquement). (§4.2)
create or replace function public.rotate_invite(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  v_expires timestamptz := now() + interval '7 days';
begin
  perform public.assert_duo_member(p_duo);
  if not public.is_duo_owner(p_duo) then raise exception 'NOT_OWNER'; end if;

  loop
    v_code := public.generate_invite_code();
    exit when not exists (select 1 from public.duos where invite_code = v_code);
  end loop;

  update public.duos
     set invite_code = v_code,
         invite_revoked = false,
         invite_expires_at = v_expires
   where id = p_duo;

  return jsonb_build_object('invite_code', v_code, 'invite_expires_at', v_expires);
end;
$$;

-- Révoque l'invitation courante (propriétaire uniquement). (§4.2)
create or replace function public.revoke_invite(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_duo_member(p_duo);
  if not public.is_duo_owner(p_duo) then raise exception 'NOT_OWNER'; end if;
  update public.duos set invite_revoked = true where id = p_duo;
  return jsonb_build_object('invite_revoked', true);
end;
$$;

-- =============================================================================
-- SESSIONS
-- =============================================================================

-- Crée une session de jeu pour un duo (§13.3 : le 2e participant est attendu).
create or replace function public.create_session(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_sess   uuid;
  v_members int;
begin
  perform public.assert_duo_member(p_duo);

  select count(*) into v_members from public.duo_members where duo_id = p_duo;

  insert into public.sessions (duo_id, state, created_by, expires_at)
  values (p_duo, 'waiting', v_uid, now() + interval '24 hours')
  returning id into v_sess;

  insert into public.session_participants (session_id, player_id)
  values (v_sess, v_uid)
  on conflict do nothing;

  -- Si le duo est déjà au complet, les deux participants sont présents.
  if v_members >= 2 then
    insert into public.session_participants (session_id, player_id)
    select v_sess, dm.player_id from public.duo_members dm where dm.duo_id = p_duo
    on conflict do nothing;
    update public.sessions set state = 'ready' where id = v_sess;
  end if;

  return public.get_session_snapshot(v_sess);
end;
$$;

-- Le second participant rejoint la session (état waiting → ready).
create or replace function public.join_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duo uuid;
  v_members int;
  v_parts int;
begin
  perform public.assert_session_member(p_session);

  select duo_id into v_duo from public.sessions where id = p_session;

  insert into public.session_participants (session_id, player_id)
  values (p_session, auth.uid())
  on conflict do nothing;

  select count(*) into v_members from public.duo_members where duo_id = v_duo;
  select count(*) into v_parts from public.session_participants where session_id = p_session and player_id in (
    select player_id from public.duo_members where duo_id = v_duo
  );

  if v_members >= 2 and v_parts >= 2 then
    update public.sessions
       set state = 'ready'
     where id = p_session and state = 'waiting';
  end if;

  return public.get_session_snapshot(p_session);
end;
$$;

-- Démarre le jeu (§20 : ready → active).
create or replace function public.start_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_members int; v_parts int; v_duo uuid;
begin
  perform public.assert_session_member(p_session);
  select duo_id into v_duo from public.sessions where id = p_session;
  select count(*) into v_members from public.duo_members where duo_id = v_duo;
  select count(*) into v_parts from public.session_participants where session_id = p_session;

  if v_members < 2 or v_parts < 2 then
    raise exception 'WAITING_FOR_PARTNER';
  end if;

  update public.sessions
     set state = 'active', started_at = coalesce(started_at, now())
   where id = p_session;

  return public.get_session_snapshot(p_session);
end;
$$;

create or replace function public.pause_session(p_session uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_session_member(p_session);
  update public.sessions set state = 'paused' where id = p_session and state = 'active';
  return public.get_session_snapshot(p_session);
end;
$$;

create or replace function public.resume_session(p_session uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  perform public.assert_session_member(p_session);
  update public.sessions set state = 'active' where id = p_session and state = 'paused';
  return public.get_session_snapshot(p_session);
end;
$$;

-- Termine la session et nettoie les données temporaires côté SERVEUR (§9, §13.9).
create or replace function public.end_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_session_member(p_session);

  update public.sessions
     set state = 'finished', finished_at = now()
   where id = p_session;

  -- §9 : suppression réelle des questions personnalisées (pas un simple masquage).
  delete from public.session_custom_questions where session_id = p_session;

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- CONSENTEMENT 18+ (§7)
-- =============================================================================
create or replace function public.set_consent(
  p_session uuid,
  p_is_adult boolean,
  p_allow_intimate boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_open_intimate boolean;
begin
  perform public.assert_session_member(p_session);

  if p_allow_intimate and not p_is_adult then
    raise exception 'ADULT_REQUIRED';
  end if;

  insert into public.session_consents (session_id, player_id, is_adult, allow_intimate)
  values (p_session, v_uid, p_is_adult, p_allow_intimate)
  on conflict (session_id, player_id) do update
    set is_adult = excluded.is_adult,
        allow_intimate = excluded.allow_intimate,
        updated_at = now();

  -- §7.2 : le retrait est immédiat. Si une question 18+ est en cours, sa
  -- progression est bloquée et une sortie sûre devient nécessaire.
  if not p_allow_intimate then
    select exists (
      select 1
      from public.question_turns t
      join public.session_question_instances i on i.id = t.instance_id
      where t.session_id = p_session
        and i.category = 'tres_intime'
        and t.state in ('awaiting_answer', 'awaiting_validation', 'clarification')
    ) into v_open_intimate;

    if v_open_intimate then
      update public.sessions set state = 'paused' where id = p_session;
    end if;
  end if;

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- TIRAGE PONDÉRÉ (§6) — cœur du jeu
-- =============================================================================
create or replace function public.draw_question(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_duo      uuid;
  v_state    public.session_state;
  v_intimate boolean;
  v_total    numeric := 0;
  v_running  numeric := 0;
  v_pick     numeric;
  rec        record;
  v_chosen   public.question_category;
  v_kind     public.instance_kind;
  v_qid      uuid;
  v_cqid     uuid;
  v_asker    uuid := v_uid;
  v_answerer uuid;
  v_instance uuid;
  v_open     int;
  v_expected uuid;
begin
  perform public.assert_session_member(p_session);

  select duo_id, state into v_duo, v_state from public.sessions where id = p_session;

  if v_state <> 'active' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

  -- §19 : interdire l'ouverture d'une nouvelle question tant qu'un tour
  -- n'est pas validé ou abandonné.
  select count(*) into v_open
  from public.question_turns
  where session_id = p_session and state in ('awaiting_answer', 'awaiting_validation', 'clarification');
  if v_open > 0 then
    raise exception 'TURN_IN_PROGRESS';
  end if;

  -- §10 : « chacun à son tour ». Seul le poseur désigné peut tirer la question.
  v_expected := public.next_asker_id(p_session);
  if v_expected is not null and v_uid <> v_expected then
    raise exception 'NOT_YOUR_TURN';
  end if;

  -- Le consentement 18+ n'est actif que si LES DEUX l'ont donné (§7.1).
  select count(*) = 2 into v_intimate
  from public.session_consents
  where session_id = p_session and is_adult and allow_intimate;

  if not coalesce(v_intimate, false) then
    v_intimate := false;
  end if;

  -- Construction des catégories admissibles avec poids et disponibilité (§6.2).
  create temporary table _pool on commit drop as
  select c.cat,
         public.category_weight(c.cat) as weight,
         (
           (select count(*) from public.questions q
              where q.category = c.cat and q.is_active
                and not exists (
                  select 1 from public.duo_used_questions u
                  where u.duo_id = v_duo and u.question_id = q.id))
           +
           (select count(*) from public.session_custom_questions cq
              where cq.session_id = p_session and cq.category = c.cat
                and not exists (
                  select 1 from public.session_question_instances i
                  where i.session_id = p_session and i.custom_question_id = cq.id))
         ) as avail
  from (values
    ('brise_glace'::public.question_category),
    ('personnalite'::public.question_category),
    ('amour'::public.question_category),
    ('secrets'::public.question_category),
    ('pimente'::public.question_category),
    ('tres_intime'::public.question_category),
    ('avenir'::public.question_category)
  ) as c(cat)
  where (c.cat <> 'tres_intime' or v_intimate);

  select coalesce(sum(weight), 0) into v_total from _pool where avail > 0;

  -- §8.3 : plus aucune question admissible → épuisement explicite, jamais de recyclage.
  if v_total = 0 then
    drop table _pool;
    return jsonb_build_object('ok', false, 'reason', 'catalog_exhausted');
  end if;

  -- Tirage pondéré : les poids sont renormalisés de fait (somme des restants).
  v_pick := random() * v_total;
  for rec in select cat, weight from _pool where avail > 0 order by weight desc, cat loop
    v_running := v_running + rec.weight;
    if v_pick < v_running then
      v_chosen := rec.cat;
      exit;
    end if;
  end loop;
  if v_chosen is null then
    select cat into v_chosen from _pool where avail > 0 order by weight desc, cat limit 1;
  end if;

  drop table _pool;

  -- Sélection d'une question concrète dans la catégorie tirée.
  select kind, qid, cqid into v_kind, v_qid, v_cqid
  from (
    select 'catalog'::public.instance_kind as kind, q.id as qid, null::uuid as cqid
    from public.questions q
    where q.category = v_chosen and q.is_active
      and not exists (
        select 1 from public.duo_used_questions u
        where u.duo_id = v_duo and u.question_id = q.id)
    union all
    select 'custom'::public.instance_kind, null, cq.id
    from public.session_custom_questions cq
    where cq.session_id = p_session and cq.category = v_chosen
      and not exists (
        select 1 from public.session_question_instances i
        where i.session_id = p_session and i.custom_question_id = cq.id)
  ) pool
  order by random()
  limit 1;

  -- §10.2 : celui qui tire pose la question, l'autre répond.
  select dm.player_id into v_answerer
  from public.duo_members dm
  where dm.duo_id = v_duo and dm.player_id <> v_uid
  limit 1;

  if v_answerer is null then
    raise exception 'NEED_TWO_PLAYERS';
  end if;

  -- §8.2 + §19 : marquage « utilisée » et attribution dans la même transaction.
  if v_kind = 'catalog' then
    insert into public.duo_used_questions (duo_id, question_id)
    values (v_duo, v_qid)
    on conflict (duo_id, question_id) do nothing;
  end if;

  insert into public.session_question_instances
    (session_id, kind, question_id, custom_question_id, category, asker_id, answerer_id)
  values
    (p_session, v_kind, v_qid, v_cqid, v_chosen, v_asker, v_answerer)
  returning id into v_instance;

  insert into public.question_turns (instance_id, session_id, state)
  values (v_instance, p_session, 'awaiting_answer');

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- RÉPONSES ÉCRITES (§10)
-- =============================================================================

-- Le répondant désigné soumet sa réponse (ou une clarification).
create or replace function public.submit_answer(
  p_instance uuid,
  p_body text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_inst   public.session_question_instances;
  v_turn   public.question_turns;
  v_body   text := btrim(coalesce(p_body, ''));
begin
  select * into v_inst from public.session_question_instances where id = p_instance;
  if v_inst.id is null then raise exception 'UNKNOWN_INSTANCE'; end if;
  perform public.assert_session_member(v_inst.session_id);

  select * into v_turn from public.question_turns where instance_id = p_instance;

  -- §19 : seule la personne désignée comme répondant peut répondre.
  if v_inst.answerer_id <> v_uid then
    raise exception 'NOT_THE_ANSWERER';
  end if;

  if v_turn.state not in ('awaiting_answer', 'clarification') then
    raise exception 'ANSWER_NOT_EXPECTED';
  end if;

  -- §19 : refuser une réponse vide.
  if v_body = '' then
    raise exception 'EMPTY_ANSWER';
  end if;

  insert into public.question_answers (instance_id, author_id, body, is_clarification)
  values (p_instance, v_uid, v_body, v_turn.state = 'clarification');

  update public.question_turns
     set state = 'awaiting_validation', updated_at = now()
   where instance_id = p_instance;

  return public.get_session_snapshot(v_inst.session_id);
end;
$$;

-- §10.2/§10.3 : SEUL l'auteur de la question valide sa satisfaction.
-- p_satisfied = false → la question reste ouverte, le tour ne change pas,
-- le répondant peut apporter une clarification écrite.
create or replace function public.validate_answer(
  p_instance uuid,
  p_satisfied boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_inst public.session_question_instances;
  v_turn public.question_turns;
begin
  select * into v_inst from public.session_question_instances where id = p_instance;
  if v_inst.id is null then raise exception 'UNKNOWN_INSTANCE'; end if;
  perform public.assert_session_member(v_inst.session_id);

  select * into v_turn from public.question_turns where instance_id = p_instance;

  if v_inst.asker_id <> v_uid then
    raise exception 'NOT_THE_ASKER';
  end if;

  if v_turn.state <> 'awaiting_validation' then
    raise exception 'NOTHING_TO_VALIDATE';
  end if;

  update public.question_turns
     set state = case
                   when p_satisfied then 'validated'::public.turn_state
                   else 'clarification'::public.turn_state
                 end,
         updated_at = now()
   where instance_id = p_instance;

  return public.get_session_snapshot(v_inst.session_id);
end;
$$;

-- §10.4 : sortie de sécurité. Permet de clore une interaction inconfortable
-- sans la valider comme satisfaisante. Transforme un « blocage » en tour clos.
create or replace function public.abandon_instance(
  p_instance uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_inst public.session_question_instances;
  v_turn public.question_turns;
begin
  select * into v_inst from public.session_question_instances where id = p_instance;
  if v_inst.id is null then raise exception 'UNKNOWN_INSTANCE'; end if;
  perform public.assert_session_member(v_inst.session_id);

  if v_inst.asker_id <> v_uid and v_inst.answerer_id <> v_uid then
    raise exception 'NOT_A_PARTICIPANT';
  end if;

  select * into v_turn from public.question_turns where instance_id = p_instance;
  if v_turn.state in ('validated', 'abandoned') then
    return public.get_session_snapshot(v_inst.session_id);
  end if;

  update public.question_turns
     set state = 'abandoned', updated_at = now()
   where instance_id = p_instance;

  insert into public.question_reports (duo_id, session_id, instance_id, reported_by, reason)
  select s.duo_id, v_inst.session_id, p_instance, v_uid,
         coalesce(nullif(btrim(coalesce(p_reason, '')), ''), 'Sortie de sécurité')
  from public.sessions s where s.id = v_inst.session_id;

  -- Si le jeu avait été mis en pause par retrait de consentement, on le relance.
  update public.sessions set state = 'active'
   where id = v_inst.session_id and state = 'paused';

  return public.get_session_snapshot(v_inst.session_id);
end;
$$;

-- =============================================================================
-- QUESTIONS PERSONNALISÉES (§9)
-- =============================================================================
create or replace function public.add_custom_question(
  p_session uuid,
  p_body text,
  p_category public.question_category default 'personnalite'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_state public.session_state;
begin
  perform public.assert_session_member(p_session);

  select state into v_state from public.sessions where id = p_session;
  if v_state not in ('ready', 'active', 'paused') then
    raise exception 'SESSION_NOT_EDITABLE';
  end if;

  if char_length(v_body) < 5 then raise exception 'QUESTION_TOO_SHORT'; end if;

  -- Validation serveur minimale (§9) : pas de contenu coercitif évident.
  if v_body ~* '(photo|nue|nus|photo intime|menace|sinon je)' then
    raise exception 'QUESTION_NOT_ALLOWED';
  end if;

  insert into public.session_custom_questions (session_id, created_by, category, body)
  values (p_session, v_uid, p_category, v_body);

  return public.get_session_snapshot(p_session);
end;
$$;

-- =============================================================================
-- CHAT PRIVÉ (§11)
-- Ne modifie JAMAIS l'état du jeu (§19).
-- =============================================================================
create or replace function public.send_message(
  p_duo uuid,
  p_body text,
  p_session uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_recent int;
  v_msg  public.messages;
begin
  perform public.assert_duo_member(p_duo);

  if v_body = '' then raise exception 'EMPTY_MESSAGE'; end if;
  if char_length(v_body) > 2000 then raise exception 'MESSAGE_TOO_LONG'; end if;

  -- Limite anti-spam simple (§16.8).
  select count(*) into v_recent
  from public.messages
  where sender_id = v_uid and created_at > now() - interval '1 minute';
  if v_recent >= 30 then raise exception 'RATE_LIMITED'; end if;

  if p_session is not null and not exists (
    select 1 from public.sessions where id = p_session and duo_id = p_duo
  ) then
    p_session := null;
  end if;

  insert into public.messages (duo_id, session_id, sender_id, body)
  values (p_duo, p_session, v_uid, v_body)
  returning * into v_msg;

  return to_jsonb(v_msg);
end;
$$;

-- =============================================================================
-- SNAPSHOT COMPLET DE SESSION (§20, §21 : reprise après reconnexion)
-- =============================================================================
create or replace function public.get_session_snapshot(p_session uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_duo   uuid;
  v_sess  public.sessions;
  v_inst  public.session_question_instances;
  v_turn  public.question_turns;
  v_body  text;
  v_intimate boolean;
begin
  perform public.assert_session_member(p_session);

  select * into v_sess from public.sessions where id = p_session;
  v_duo := v_sess.duo_id;

  select count(*) = 2 into v_intimate
  from public.session_consents
  where session_id = p_session and is_adult and allow_intimate;

  -- Tour courant = tour non clos le plus récent.
  select i.* into v_inst
  from public.session_question_instances i
  join public.question_turns t on t.instance_id = i.id
  where i.session_id = p_session and t.state in ('awaiting_answer', 'awaiting_validation', 'clarification')
  order by i.created_at desc
  limit 1;

  if v_inst.id is not null then
    select * into v_turn from public.question_turns where instance_id = v_inst.id;
    v_body := coalesce(
      (select q.body from public.questions q where q.id = v_inst.question_id),
      (select cq.body from public.session_custom_questions cq where cq.id = v_inst.custom_question_id),
      ''
    );
  end if;

  return jsonb_build_object(
    'session', to_jsonb(v_sess),
    'duo', (select jsonb_build_object('id', d.id, 'name', d.name) from public.duos d where d.id = v_duo),
    'intimate_enabled', coalesce(v_intimate, false),
    'next_asker_id', public.next_asker_id(p_session),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'player_id', dm.player_id,
        'pseudo', coalesce(p.pseudo, 'Anonyme'),
        'role', dm.role,
        'present', exists (
          select 1 from public.session_participants sp
          where sp.session_id = p_session and sp.player_id = dm.player_id
        )
      ) order by dm.joined_at), '[]'::jsonb)
      from public.duo_members dm
      left join public.players p on p.id = dm.player_id
      where dm.duo_id = v_duo
    ),
    'consents', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'player_id', sc.player_id,
        'is_adult', sc.is_adult,
        'allow_intimate', sc.allow_intimate
      )), '[]'::jsonb)
      from public.session_consents sc where sc.session_id = p_session
    ),
    'turn', case when v_inst.id is null then null else jsonb_build_object(
      'instance_id', v_inst.id,
      'category', v_inst.category,
      'kind', v_inst.kind,
      'question', v_body,
      'asker_id', v_inst.asker_id,
      'answerer_id', v_inst.answerer_id,
      'state', v_turn.state,
      'answers', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', a.id,
          'author_id', a.author_id,
          'body', a.body,
          'is_clarification', a.is_clarification,
          'created_at', a.created_at
        ) order by a.created_at), '[]'::jsonb)
        from public.question_answers a where a.instance_id = v_inst.id
      )
    ) end,
    'remaining_by_category', (
      select coalesce(jsonb_object_agg(cat, cnt), '{}'::jsonb)
      from (
        select c.cat::text as cat,
               (select count(*) from public.questions q
                  where q.category = c.cat and q.is_active
                    and not exists (
                      select 1 from public.duo_used_questions u
                      where u.duo_id = v_duo and u.question_id = q.id)) as cnt
        from (values
          ('brise_glace'::public.question_category),
          ('personnalite'::public.question_category),
          ('amour'::public.question_category),
          ('secrets'::public.question_category),
          ('pimente'::public.question_category),
          ('tres_intime'::public.question_category),
          ('avenir'::public.question_category)
        ) as c(cat)
      ) counts
    )
  );
end;
$$;

-- =============================================================================
-- SUPPRESSION COMPLÈTE D'UN DUO (§15.3)
-- =============================================================================
create or replace function public.delete_duo(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.assert_duo_member(p_duo);
  if not public.is_duo_owner(p_duo) then raise exception 'NOT_OWNER'; end if;

  -- ON DELETE CASCADE propage la suppression à tout le contenu privé
  -- (sessions, réponses, messages, consentements, historique, signalements).
  delete from public.duos where id = p_duo;

  return jsonb_build_object('deleted', true);
end;
$$;

-- =============================================================================
-- Droits d'exécution : uniquement les utilisateurs authentifiés.
-- =============================================================================
do $$
declare f record;
begin
  for f in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'create_duo','join_duo','get_my_duos','get_duo_invite','rotate_invite',
        'revoke_invite','create_session','join_session','start_session',
        'pause_session','resume_session','end_session','set_consent',
        'draw_question','submit_answer','validate_answer','abandon_instance',
        'add_custom_question','send_message','get_session_snapshot','delete_duo'
      )
  loop
    execute format('revoke all on function public.%I(%s) from public, anon', f.proname, f.args);
    execute format('grant execute on function public.%I(%s) to authenticated', f.proname, f.args);
  end loop;
end;
$$;
