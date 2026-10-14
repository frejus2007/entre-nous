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
  v_duo uuid;
  v_state public.session_state;
  v_category public.question_category;
  v_asker uuid;
  v_answerer uuid;
  v_custom_question uuid;
  v_instance uuid;
begin
  perform public.assert_session_member(p_session);

  select duo_id, state, question_category
  into v_duo, v_state, v_category
  from public.sessions
  where id = p_session
  for update;

  if v_state <> 'active' then
    raise exception 'SESSION_NOT_ACTIVE';
  end if;

  if exists (
    select 1
    from public.question_turns
    where session_id = p_session
      and state in ('awaiting_answer', 'awaiting_validation', 'clarification')
  ) then
    raise exception 'TURN_IN_PROGRESS';
  end if;

  v_asker := public.next_asker_id(p_session);
  if v_asker is null or v_asker <> v_uid then
    raise exception 'NOT_YOUR_TURN';
  end if;

  if v_category is not null and p_category <> v_category then
    raise exception 'CATEGORY_LOCKED';
  end if;
  if char_length(v_body) < 5 then raise exception 'QUESTION_TOO_SHORT'; end if;
  if v_body ~* '(photo|nue|nus|photo intime|menace|sinon je)' then
    raise exception 'QUESTION_NOT_ALLOWED';
  end if;

  select player_id into v_answerer
  from public.duo_members
  where duo_id = v_duo and player_id <> v_asker
  order by joined_at
  limit 1;

  if v_answerer is null then
    raise exception 'NEED_TWO_PLAYERS';
  end if;

  insert into public.session_custom_questions (session_id, created_by, category, body)
  values (p_session, v_uid, coalesce(v_category, p_category), v_body)
  returning id into v_custom_question;

  insert into public.session_question_instances
    (session_id, kind, custom_question_id, category, asker_id, answerer_id)
  values
    (p_session, 'custom', v_custom_question, coalesce(v_category, p_category), v_asker, v_answerer)
  returning id into v_instance;

  insert into public.question_turns (instance_id, session_id, state)
  values (v_instance, p_session, 'awaiting_answer');

  return public.get_session_snapshot(p_session);
end;
$$;
