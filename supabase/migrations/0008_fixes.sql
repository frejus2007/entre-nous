-- =============================================================================
-- Entre Nous — 0008_fixes.sql
-- 1. Nettoyage et robustesse des fonctions Admin (évite le conflit enum/text)
-- 2. Dédoublonnage des sessions dans create_session
-- 3. Helper get_active_session pour synchroniser les deux participants
-- 4. Fonction claim_admin avec mot de passe
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Nettoyage des anciennes signatures Admin
-- -----------------------------------------------------------------------------
drop function if exists public._admin_next_code(text);
drop function if exists public._admin_next_code(public.question_category);
drop function if exists public.admin_import_questions(text, text[]);
drop function if exists public.admin_import_questions(public.question_category, text[]);

create or replace function public._admin_next_code(p_category text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pref text;
  v_max  int;
  v_cat  public.question_category;
begin
  begin
    v_cat := p_category::public.question_category;
  exception when others then
    raise exception 'CATEGORIE_INVALIDE';
  end;

  v_pref := case v_cat
    when 'brise_glace'   then 'bg'
    when 'personnalite'  then 'ph'
    when 'amour'         then 'as'
    when 'secrets'       then 'sc'
    when 'pimente'       then 'pi'
    when 'tres_intime'   then 'ti'
    when 'avenir'        then 'av'
    else null
  end;
  if v_pref is null then
    raise exception 'CATEGORIE_INVALIDE';
  end if;

  select coalesce(max(substring(code from length(v_pref)+2)::int), 100)
    into v_max
  from public.questions
  where category = v_cat
    and code ~ ('^' || v_pref || '-[0-9]+$');

  return v_pref || '-' || (v_max + 1);
end;
$$;

create or replace function public.admin_import_questions(
  p_category text,
  p_questions text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_cat  public.question_category;
  v_q    text;
  v_body text;
  v_code text;
  v_ins  int := 0;
  v_dup  int := 0;
  v_skip int := 0;
  v_len  int;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if not public.is_admin() then
    raise exception 'NOT_ADMIN';
  end if;

  begin
    v_cat := p_category::public.question_category;
  exception when others then
    raise exception 'CATEGORIE_INVALIDE';
  end;

  if p_questions is null then
    return jsonb_build_object('inserted', 0, 'duplicates', 0, 'skipped', 0);
  end if;

  foreach v_q in array p_questions loop
    v_q := trim(v_q);
    if v_q = '' or left(v_q, 1) = '#' then
      v_skip := v_skip + 1;
      continue;
    end if;

    v_body := v_q;
    if char_length(v_body) > 400 then
      v_body := left(v_body, 397) || '...';
    end if;

    v_len := char_length(btrim(v_body));
    if v_len < 5 or v_len > 400 then
      v_skip := v_skip + 1;
      continue;
    end if;

    if exists (
      select 1 from public.questions q
      where q.category = v_cat
        and lower(regexp_replace(q.body, '\s+', ' ', 'g')) =
            lower(regexp_replace(v_body,  '\s+', ' ', 'g'))
    ) then
      v_dup := v_dup + 1;
      continue;
    end if;

    v_code := public._admin_next_code(p_category);
    insert into public.questions (code, category, body, is_active)
    values (v_code, v_cat, v_body, true)
    on conflict (code) do nothing;
    v_ins := v_ins + 1;
  end loop;

  return jsonb_build_object('inserted', v_ins, 'duplicates', v_dup, 'skipped', v_skip, 'total', array_length(p_questions, 1));
end;
$$;

revoke all on function public._admin_next_code(text) from public, anon;
grant execute on function public._admin_next_code(text) to authenticated;
revoke all on function public.admin_import_questions(text, text[]) from public, anon;
grant execute on function public.admin_import_questions(text, text[]) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. Dédoublonnage dans create_session
-- Si une session en cours existe déjà pour le duo, on la réutilise.
-- -----------------------------------------------------------------------------
create or replace function public.create_session(p_duo uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_sess    uuid;
  v_members int;
begin
  perform public.assert_duo_member(p_duo);

  select count(*) into v_members from public.duo_members where duo_id = p_duo;

  -- Chercher une session non terminée et non expirée
  select id into v_sess
  from public.sessions
  where duo_id = p_duo
    and state in ('waiting', 'ready', 'active', 'paused')
    and expires_at > now()
  order by created_at desc
  limit 1;

  if v_sess is not null then
    -- S'assurer que le joueur est participant
    insert into public.session_participants (session_id, player_id)
    values (v_sess, v_uid)
    on conflict do nothing;

    if v_members >= 2 then
      insert into public.session_participants (session_id, player_id)
      select v_sess, dm.player_id from public.duo_members dm where dm.duo_id = p_duo
      on conflict do nothing;
      update public.sessions set state = 'ready' where id = v_sess and state = 'waiting';
    end if;

    return public.get_session_snapshot(v_sess);
  end if;

  insert into public.sessions (duo_id, state, created_by, expires_at)
  values (p_duo, 'waiting', v_uid, now() + interval '24 hours')
  returning id into v_sess;

  insert into public.session_participants (session_id, player_id)
  values (v_sess, v_uid)
  on conflict do nothing;

  if v_members >= 2 then
    insert into public.session_participants (session_id, player_id)
    select v_sess, dm.player_id from public.duo_members dm where dm.duo_id = p_duo
    on conflict do nothing;
    update public.sessions set state = 'ready' where id = v_sess;
  end if;

  return public.get_session_snapshot(v_sess);
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. get_active_session : permet au deuxième joueur de retrouver la session
-- -----------------------------------------------------------------------------
create or replace function public.get_active_session(p_duo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sess uuid;
begin
  perform public.assert_duo_member(p_duo);

  select id into v_sess
  from public.sessions
  where duo_id = p_duo
    and state in ('waiting', 'ready', 'active', 'paused')
    and expires_at > now()
  order by created_at desc
  limit 1;

  if v_sess is null then
    return null;
  end if;

  return public.get_session_snapshot(v_sess);
end;
$$;

revoke all on function public.get_active_session(uuid) from public, anon;
grant execute on function public.get_active_session(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. claim_admin : déverrouillage de l'accès administrateur par mot de passe
-- -----------------------------------------------------------------------------
create or replace function public.claim_admin(p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;

  if coalesce(btrim(p_secret), '') not in ('entrenous-admin', 'admin2026', 'admin') then
    raise exception 'INVALID_SECRET';
  end if;

  update public.players
     set is_admin = true
   where id = v_uid;

  return true;
end;
$$;

revoke all on function public.claim_admin(text) from public, anon;
grant execute on function public.claim_admin(text) to authenticated;
