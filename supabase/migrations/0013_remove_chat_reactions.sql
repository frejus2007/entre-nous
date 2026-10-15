-- =============================================================================
-- Entre Nous — 0013_remove_chat_reactions.sql
-- Retire les réactions du chat et leurs données persistées.
-- =============================================================================

drop function if exists public.toggle_message_reaction(uuid, text);
drop table if exists public.message_reactions cascade;
