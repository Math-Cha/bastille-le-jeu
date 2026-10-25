-- BASTILLE — migration du 25/10/2026 (3) : un message sur le mur après chaque partie, gagnée ou perdue
-- Idempotente : peut être rejouée sans risque.
alter table public.comments add column if not exists stage int;
alter table public.comments add column if not exists score bigint;

create or replace function public.post_game_comment(p_gkey uuid, p_visitor text, p_name text, p_body text) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); g record; b text; n text; nid bigint;
begin
  select * into g from public.games where gkey = p_gkey and created_at > now() - interval '2 hours'
    and (visitor = p_visitor or (uid is not null and user_id = uid)) limit 1;
  if not found then raise exception 'not_found'; end if;
  if exists (select 1 from public.comments where gkey = p_gkey) then raise exception 'already'; end if;
  if uid is not null and exists (select 1 from public.profiles where id = uid and banned) then raise exception 'banned'; end if;
  b := btrim(regexp_replace(regexp_replace(coalesce(p_body,''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  n := btrim(regexp_replace(regexp_replace(coalesce(p_name,''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  if char_length(b) < 2 or char_length(b) > 280 then raise exception 'length'; end if;
  if uid is null and (char_length(n) < 2 or char_length(n) > 24) then raise exception 'name'; end if;
  if (b || ' ' || n) ~* '(https?://|www\.|[a-z0-9-]+\.(com|fr|net|org|io|ly|gg|me|tv|co|xyz|info|biz|ru|be|ch)\b|@[a-z0-9_]{3,})' then raise exception 'link'; end if;
  if public.has_banned(b) or public.has_banned(n) then raise exception 'banned_term'; end if;
  if (select count(*) from public.comments where visitor = p_visitor and created_at > now() - interval '1 day') >= 10 then raise exception 'rate_limited'; end if;
  insert into public.comments (user_id, body, side, won, era, time_s, anon_name, gkey, visitor, stage, score)
  values (uid, b, g.side, coalesce(g.won,false), g.era, case when g.won then g.time_s end, case when uid is null then n end, p_gkey, left(p_visitor, 64), g.stage, g.score) returning id into nid;
  return nid;
end $$;
revoke execute on function public.post_game_comment(uuid,text,text,text) from public;
grant execute on function public.post_game_comment(uuid,text,text,text) to anon, authenticated;

drop function if exists public.wall(timestamptz,int);
create or replace function public.wall(p_before timestamptz default null, p_limit int default 30)
returns table (id bigint, pseudo text, body text, side text, best bigint, created_at timestamptz, mine boolean, won boolean, era text, time_s int, stage int, score bigint)
language sql stable security definer set search_path = public as $$
  select c.id, coalesce(p.pseudo, c.anon_name, 'Joueur'), c.body, c.side,
         case when c.user_id is null then null else (select max(g.score) from public.games g where g.user_id = c.user_id and g.side = coalesce(c.side, g.side)) end,
         c.created_at, c.user_id is not null and c.user_id = auth.uid(), c.won, c.era, c.time_s, c.stage, c.score
  from public.comments c left join public.profiles p on p.id = c.user_id
  where not c.hidden and (c.user_id is null or not coalesce(p.banned,false)) and (p_before is null or c.created_at < p_before)
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 50);
$$;
revoke execute on function public.wall(timestamptz,int) from public;
grant execute on function public.wall(timestamptz,int) to anon, authenticated;
