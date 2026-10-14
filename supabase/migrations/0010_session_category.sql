-- The owner selects one category for the whole session before starting.
alter table public.sessions
  add column if not exists question_category public.question_category;

create or replace function public.set_session_category(
  p_session uuid,
  p_category text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_duo uuid;
  v_category public.question_category;
  v_state public.session_state;
begin
  perform public.assert_session_member(p_session);

  begin
    v_category := p_category::public.question_category;
  exception when others then
    raise exception 'CATEGORIE_INVALIDE';
  end;

  select duo_id, state into v_duo, v_state
  from public.sessions where id = p_session;

  if not public.is_duo_owner(v_duo) then
    raise exception 'NOT_OWNER';
  end if;
  if v_state <> 'ready' then
    raise exception 'SESSION_NOT_EDITABLE';
  end if;
  if not exists (
    select 1
    from public.questions q
    where q.category = v_category
      and q.is_active
      and not exists (
        select 1 from public.duo_used_questions u
        where u.duo_id = v_duo and u.question_id = q.id
      )
  ) then
    raise exception 'CATEGORY_EXHAUSTED';
  end if;

  update public.sessions
  set question_category = v_category
  where id = p_session;

  return public.get_session_snapshot(p_session);
end;
$$;

revoke all on function public.set_session_category(uuid, text) from public, anon;
grant execute on function public.set_session_category(uuid, text) to authenticated;

create or replace function public.start_session(p_session uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_members int;
  v_parts int;
  v_duo uuid;
  v_category public.question_category;
begin
  perform public.assert_session_member(p_session);
  select duo_id, question_category into v_duo, v_category
  from public.sessions where id = p_session;

  if not public.is_duo_owner(v_duo) then
    raise exception 'NOT_OWNER';
  end if;
  if v_category is null then
    raise exception 'CATEGORY_REQUIRED';
  end if;

  select count(*) into v_members from public.duo_members where duo_id = v_duo;
  select count(*) into v_parts from public.session_participants where session_id = p_session;
  if v_members < 2 or v_parts < 2 then
    raise exception 'WAITING_FOR_PARTNER';
  end if;

  if not exists (
    select 1
    from public.questions q
    where q.category = v_category
      and q.is_active
      and not exists (
        select 1 from public.duo_used_questions u
        where u.duo_id = v_duo and u.question_id = q.id
      )
  ) then
    raise exception 'CATEGORY_EXHAUSTED';
  end if;

  if v_category = 'tres_intime' and (
    select count(*) from public.session_consents
    where session_id = p_session and is_adult and allow_intimate
  ) < 2 then
    raise exception 'INTIMATE_REQUIRED';
  end if;

  update public.sessions
  set state = 'active', started_at = coalesce(started_at, now())
  where id = p_session and state = 'ready';

  return public.get_session_snapshot(p_session);
end;
$$;

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
  v_category public.question_category;
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

  select duo_id, state, question_category
  into v_duo, v_state, v_category
  from public.sessions where id = p_session;

  if v_state <> 'active' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

  select count(*) into v_open
  from public.question_turns
  where session_id = p_session and state in ('awaiting_answer', 'awaiting_validation', 'clarification');
  if v_open > 0 then
    raise exception 'TURN_IN_PROGRESS';
  end if;

  v_expected := public.next_asker_id(p_session);
  if v_expected is not null and v_uid <> v_expected then
    raise exception 'NOT_YOUR_TURN';
  end if;

  select count(*) = 2 into v_intimate
  from public.session_consents
  where session_id = p_session and is_adult and allow_intimate;

  if not coalesce(v_intimate, false) then
    v_intimate := false;
  end if;

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
  where (c.cat <> 'tres_intime' or v_intimate)
    and (v_category is null or c.cat = v_category);

  select coalesce(sum(weight), 0) into v_total from _pool where avail > 0;
  if v_total = 0 then
    drop table _pool;
    return jsonb_build_object('ok', false, 'reason', 'catalog_exhausted');
  end if;

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

  select dm.player_id into v_answerer
  from public.duo_members dm
  where dm.duo_id = v_duo and dm.player_id <> v_uid
  limit 1;

  if v_answerer is null then
    raise exception 'NEED_TWO_PLAYERS';
  end if;

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
  v_uid uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_state public.session_state;
  v_category public.question_category;
begin
  perform public.assert_session_member(p_session);

  select state, question_category into v_state, v_category
  from public.sessions where id = p_session;
  if v_state not in ('ready', 'active', 'paused') then
    raise exception 'SESSION_NOT_EDITABLE';
  end if;

  if v_category is not null and p_category <> v_category then
    raise exception 'CATEGORY_LOCKED';
  end if;
  if char_length(v_body) < 5 then raise exception 'QUESTION_TOO_SHORT'; end if;
  if v_body ~* '(photo|nue|nus|photo intime|menace|sinon je)' then
    raise exception 'QUESTION_NOT_ALLOWED';
  end if;

  insert into public.session_custom_questions (session_id, created_by, category, body)
  values (p_session, v_uid, coalesce(v_category, p_category), v_body);

  return public.get_session_snapshot(p_session);
end;
$$;
