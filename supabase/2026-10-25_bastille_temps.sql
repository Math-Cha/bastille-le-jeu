-- BASTILLE — migration du 25/10/2026 : victoire (entrée dans la Bastille), temps de course, époque
-- Idempotente : peut être rejouée sans risque.
alter table public.games add column if not exists won boolean not null default false;
alter table public.games add column if not exists time_s int check (time_s is null or (time_s between 60 and 86400));
alter table public.games add column if not exists era text check (era is null or length(era) <= 12);
grant insert (gkey, visitor, side, score, stage, bosses, duration_s, device, tenue, arme, exo, picked, perks, won, time_s, era) on public.games to anon, authenticated;

-- vraisemblance : une victoire suppose les 4 étapes et un temps cohérent avec la durée réelle
create or replace function public.games_won_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.won then
    if new.stage < 4 or new.time_s is null or new.time_s < 120 or new.time_s < new.duration_s - 5 or new.time_s > new.duration_s + 900 then raise exception 'implausible_win'; end if;
  else new.time_s := null;
  end if;
  return new;
end $$;
drop trigger if exists games_won_guard on public.games;
create trigger games_won_guard before insert on public.games for each row execute function public.games_won_guard();
create index if not exists games_side_time on public.games (side, time_s) where won and user_id is not null;

-- Classement au temps : meilleure prise de la Bastille de chaque joueur vérifié (non exclu), top 50, sans e-mail
create or replace function public.leaderboard_time(p_side text, p_period text)
returns table (rank bigint, pseudo text, time_s int, score bigint, tenue text, era text, played_at timestamptz)
language sql stable security definer set search_path = public as $$
  with g as (
    select distinct on (gm.user_id) gm.user_id, gm.time_s, gm.score, gm.tenue, gm.era, gm.created_at
    from public.games gm join public.profiles pr on pr.id = gm.user_id and not pr.banned
    where gm.won and gm.time_s is not null and gm.side = p_side
      and gm.created_at >= case p_period when 'day' then date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'
                                         when 'week' then now() - interval '7 days' else '-infinity'::timestamptz end
    order by gm.user_id, gm.time_s, gm.created_at
  )
  select rank() over (order by g.time_s, g.created_at), p.pseudo, g.time_s, g.score::bigint, g.tenue, g.era, g.created_at
  from g join public.profiles p on p.id = g.user_id
  order by g.time_s, g.created_at
  limit 50;
$$;
create or replace function public.my_rank_time(p_side text, p_period text)
returns table (rank bigint, time_s int, total bigint, pseudo text)
language sql stable security definer set search_path = public as $$
  with g as (
    select gm.user_id, min(gm.time_s) as time_s
    from public.games gm join public.profiles pr on pr.id = gm.user_id and not pr.banned
    where gm.won and gm.time_s is not null and gm.side = p_side
      and gm.created_at >= case p_period when 'day' then date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'
                                         when 'week' then now() - interval '7 days' else '-infinity'::timestamptz end
    group by gm.user_id
  ), r as (select user_id, time_s, rank() over (order by time_s) as rank, count(*) over () as total from g)
  select r.rank, r.time_s, r.total, p.pseudo from r join public.profiles p on p.id = r.user_id where r.user_id = auth.uid();
$$;
revoke all on function public.leaderboard_time(text,text), public.my_rank_time(text,text) from public;
grant execute on function public.leaderboard_time(text,text) to anon, authenticated;
grant execute on function public.my_rank_time(text,text) to authenticated;
