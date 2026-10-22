-- BASTILLE — schéma Supabase (v2)
-- À coller dans Supabase : SQL Editor → New query → Run. Peut être relancé sans risque.
-- Remplacez l'adresse de la ligne « insert into public.admins » par l'e-mail administrateur si besoin.

create extension if not exists pgcrypto;

-- ============ Administrateurs ============
create table if not exists public.admins (email text primary key);
insert into public.admins (email) values ('mathieu.chaplain@facildata.com') on conflict do nothing;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins a where lower(a.email) = lower(auth.jwt() ->> 'email'));
$$;

-- ============ Profils joueurs (créés à la première connexion par code) ============
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  news_consent boolean not null default false,
  ref_code text unique not null default substr(replace(gen_random_uuid()::text,'-',''),1,8),
  referred_by uuid references public.profiles(id) on delete set null,
  credits_bonus int not null default 0,
  created_at timestamptz not null default now()
);

create or replace function public.on_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.on_new_user();

-- Consentement newsletter (le joueur ne peut modifier que le sien)
create or replace function public.set_news_consent(ok boolean) returns void
language sql security definer set search_path = public as $$
  update public.profiles set news_consent = ok where id = auth.uid();
$$;

-- Parrainage : une seule fois, dans les 24 h après l'inscription, pas soi-même.
-- Parrain +200 crédits, filleul +100 crédits de bienvenue.
create or replace function public.claim_referral(code text) returns int
language plpgsql security definer set search_path = public as $$
declare me public.profiles; ref public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.referred_by is not null or me.created_at < now() - interval '1 day' then return 0; end if;
  select * into ref from public.profiles where ref_code = code;
  if ref.id is null or ref.id = me.id then return 0; end if;
  update public.profiles set referred_by = ref.id, credits_bonus = credits_bonus + 100 where id = me.id;
  update public.profiles set credits_bonus = credits_bonus + 200 where id = ref.id;
  return 100;
end $$;

-- ============ Parties ============
create table if not exists public.games (
  id bigint generated always as identity primary key,
  visitor text not null check (length(visitor) <= 64),
  side text not null check (side in ('bloc','police')),
  score bigint not null default 0 check (score >= 0 and score < 1000000000000),
  stage int not null default 1 check (stage between 1 and 999),
  bosses int not null default 0 check (bosses between 0 and 999),
  duration_s int not null default 0 check (duration_s between 0 and 86400),
  device text check (length(device) <= 20),
  created_at timestamptz not null default now()
);
alter table public.games add column if not exists user_id uuid default auth.uid() references auth.users(id) on delete set null;
alter table public.games add column if not exists tenue text check (length(tenue) <= 40);
alter table public.games add column if not exists arme text check (length(arme) <= 40);
alter table public.games add column if not exists exo text check (length(exo) <= 40);
alter table public.games add column if not exists picked text check (length(picked) <= 300);
alter table public.games add column if not exists perks text check (length(perks) <= 100);
alter table public.games add column if not exists clip text check (length(clip) <= 200);
alter table public.games add column if not exists mailed_at timestamptz;
alter table public.games add column if not exists gkey uuid unique;

-- Le joueur qui se connecte juste après sa partie la rattache à son compte (dans l'heure, si elle n'a pas de propriétaire)
create or replace function public.claim_game(k uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update public.games set user_id = auth.uid()
  where gkey = k and user_id is null and created_at > now() - interval '1 hour';
  return exists (select 1 from public.games where gkey = k and user_id = auth.uid());
end $$;

-- Le joueur rattache la vidéo à SA partie (fichier rangé dans son propre dossier)
create or replace function public.set_game_clip(k uuid, path text) returns void
language sql security definer set search_path = public as $$
  update public.games set clip = path
  where gkey = k and user_id = auth.uid() and clip is null and path like auth.uid()::text || '/%';
$$;

-- ============ Visites ============
create table if not exists public.visits (
  id bigint generated always as identity primary key,
  visitor text not null check (length(visitor) <= 64),
  referrer text check (length(referrer) <= 300),
  device text check (length(device) <= 20),
  created_at timestamptz not null default now()
);
alter table public.visits add column if not exists ref text check (length(ref) <= 16);

-- ============ Sécurité (Row Level Security) ============
alter table public.admins   enable row level security;
alter table public.profiles enable row level security;
alter table public.games    enable row level security;
alter table public.visits   enable row level security;

drop policy if exists "admin self" on public.admins;
drop policy if exists "own profile" on public.profiles;
drop policy if exists "admin profiles" on public.profiles;
drop policy if exists "insert game" on public.games;
drop policy if exists "own games" on public.games;
drop policy if exists "admin games" on public.games;
drop policy if exists "insert visit" on public.visits;
drop policy if exists "admin visits" on public.visits;

create policy "admin self"     on public.admins   for select to authenticated using (public.is_admin());
create policy "own profile"    on public.profiles for select to authenticated using (id = auth.uid());
create policy "admin profiles" on public.profiles for select to authenticated using (public.is_admin());
create policy "insert game"    on public.games    for insert to anon, authenticated with check (user_id is null or user_id = auth.uid());
create policy "own games"      on public.games    for select to authenticated using (user_id = auth.uid());
create policy "admin games"    on public.games    for select to authenticated using (public.is_admin());
create policy "insert visit"   on public.visits   for insert to anon, authenticated with check (true);
create policy "admin visits"   on public.visits   for select to authenticated using (public.is_admin());

grant insert on public.games, public.visits to anon, authenticated;
grant select on public.games, public.visits, public.profiles, public.admins to authenticated;
grant execute on function public.set_news_consent(boolean), public.claim_referral(text), public.claim_game(uuid), public.set_game_clip(uuid,text) to authenticated;

-- ============ Vidéos (stockage public en lecture, dépôt par le joueur connecté dans son dossier) ============
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('clips', 'clips', true, 15728640, array['video/mp4','video/webm'])
on conflict (id) do update set public = true, file_size_limit = 15728640, allowed_mime_types = array['video/mp4','video/webm'];

drop policy if exists "clip upload" on storage.objects;
create policy "clip upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);

-- Ancienne table de la v1 (inscriptions sans compte) : conservée si elle existe
-- (les nouveaux e-mails sont dans profiles)

-- ============ Classement des meilleurs joueurs ============
-- Pseudos générés automatiquement (aucun texte libre : pas de modération nécessaire)
alter table public.profiles add column if not exists pseudo text unique;

create or replace function public.gen_pseudo() returns text
language plpgsql volatile set search_path = public as $$
declare
  n text[] := array['Pavé','Bouclier','Gilet','Mégaphone','Casque','Sifflet','Kiosque','Képi','Fumigène','Brassard','Tract','Lampadaire','Cortège','Plot','Pigeon','Croissant'];
  a text[] := array['Furtif','Zen','Enragé','Pressé','Têtu','Ninja','Distrait','Fougueux','Calme','Masqué','Tranquille','Rapide','Lyrique','Grognon','Héroïque','Perdu'];
  p text; i int := 0;
begin
  loop
    p := n[1 + floor(random()*array_length(n,1))::int] || ' ' || a[1 + floor(random()*array_length(a,1))::int] || ' ' || (10 + floor(random()*990))::int;
    exit when not exists (select 1 from public.profiles where pseudo = p) or i > 20;
    i := i + 1;
  end loop;
  return p;
end $$;

update public.profiles set pseudo = public.gen_pseudo() where pseudo is null;

create or replace function public.on_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, pseudo) values (new.id, new.email, public.gen_pseudo()) on conflict (id) do nothing;
  return new;
end $$;

create or replace function public.reroll_pseudo() returns text
language plpgsql security definer set search_path = public as $$
declare p text := public.gen_pseudo();
begin
  update public.profiles set pseudo = p where id = auth.uid();
  return p;
end $$;

-- Meilleure partie de chaque joueur vérifié, par camp et par période ('day', 'week', 'all') — top 50, sans e-mail
create or replace function public.leaderboard(p_side text, p_period text)
returns table (rank bigint, pseudo text, score bigint, stage int, tenue text, played_at timestamptz)
language sql stable security definer set search_path = public as $$
  with g as (
    select distinct on (gm.user_id) gm.user_id, gm.score, gm.stage, gm.tenue, gm.created_at
    from public.games gm
    where gm.user_id is not null and gm.side = p_side
      and gm.created_at >= case p_period when 'day' then date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'
                                         when 'week' then now() - interval '7 days' else '-infinity'::timestamptz end
    order by gm.user_id, gm.score desc, gm.created_at
  )
  select rank() over (order by g.score desc, g.created_at), p.pseudo, g.score, g.stage, g.tenue, g.created_at
  from g join public.profiles p on p.id = g.user_id
  order by g.score desc, g.created_at
  limit 50;
$$;

-- Rang du joueur connecté
create or replace function public.my_rank(p_side text, p_period text)
returns table (rank bigint, score bigint, total bigint, pseudo text)
language sql stable security definer set search_path = public as $$
  with g as (
    select gm.user_id, max(gm.score) as score
    from public.games gm
    where gm.user_id is not null and gm.side = p_side
      and gm.created_at >= case p_period when 'day' then date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'
                                         when 'week' then now() - interval '7 days' else '-infinity'::timestamptz end
    group by gm.user_id
  ), r as (select user_id, score, rank() over (order by score desc) as rank, count(*) over () as total from g)
  select r.rank, r.score, r.total, p.pseudo from r join public.profiles p on p.id = r.user_id where r.user_id = auth.uid();
$$;

grant execute on function public.leaderboard(text,text) to anon, authenticated;
grant execute on function public.my_rank(text,text), public.reroll_pseudo() to authenticated;
create index if not exists games_side_score on public.games (side, score desc) where user_id is not null;

-- ============ Durcissement sécurité ============
-- 1. Colonnes autorisées à l'écriture : le navigateur ne peut jamais fixer user_id, clip, mailed_at, created_at
-- (Supabase accorde par défaut tous les droits : on repart de zéro, en plus des règles RLS)
revoke all on public.games, public.visits, public.profiles, public.admins from anon, authenticated;
grant select on public.games, public.visits, public.profiles, public.admins to authenticated;
grant insert (gkey, visitor, side, score, stage, bosses, duration_s, device, tenue, arme, exo, picked, perks) on public.games to anon, authenticated;
grant insert (visitor, referrer, device, ref) on public.visits to anon, authenticated;

-- 2. Exclusion d'un joueur du classement (tricheur) par l'administrateur
alter table public.profiles add column if not exists banned boolean not null default false;
create or replace function public.admin_set_banned(uid uuid, ban boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.profiles set banned = ban where id = uid;
end $$;
grant execute on function public.admin_set_banned(uuid, boolean) to authenticated;

-- 3. Contrôles de vraisemblance et limites de fréquence à l'insertion d'une partie
create or replace function public.games_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.duration_s < 3 then raise exception 'too_short'; end if;
  if new.stage > 1 + new.duration_s / 12 then raise exception 'implausible_stage'; end if;
  if new.bosses > new.stage * 2 then raise exception 'implausible_bosses'; end if;
  if new.side = 'bloc'   and new.score > 100000 + new.duration_s * 60000 then raise exception 'implausible_score'; end if;
  if new.side = 'police' and new.score > 100 + new.duration_s * 60 then raise exception 'implausible_score'; end if;
  if exists (select 1 from public.games where visitor = new.visitor and created_at > now() - interval '5 seconds') then raise exception 'rate_limited'; end if;
  if (select count(*) from public.games where visitor = new.visitor and created_at > now() - interval '1 day') >= 300 then raise exception 'rate_limited'; end if;
  return new;
end $$;
drop trigger if exists games_guard on public.games;
create trigger games_guard before insert on public.games for each row execute function public.games_guard();

create or replace function public.visits_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.visits where visitor = new.visitor and created_at > now() - interval '1 day') >= 50 then raise exception 'rate_limited'; end if;
  return new;
end $$;
drop trigger if exists visits_guard on public.visits;
create trigger visits_guard before insert on public.visits for each row execute function public.visits_guard();

-- 4. Parrainage sans plafond (viralité) : un filleul ne compte qu'une fois, dans les 24 h, jamais soi-même
create or replace function public.claim_referral(code text) returns int
language plpgsql security definer set search_path = public as $$
declare me public.profiles; ref public.profiles;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or me.referred_by is not null or me.created_at < now() - interval '1 day' then return 0; end if;
  select * into ref from public.profiles where ref_code = code;
  if ref.id is null or ref.id = me.id then return 0; end if;
  update public.profiles set referred_by = ref.id, credits_bonus = credits_bonus + 100 where id = me.id;
  update public.profiles set credits_bonus = credits_bonus + 200 where id = ref.id;
  return 100;
end $$;

-- 5. Vidéos : dépôt autorisé seulement pour SA partie récente, sans vidéo, dans SON dossier ; suppression de ses propres vidéos
drop policy if exists "clip upload" on storage.objects;
create policy "clip upload" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'clips'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.games g
                where g.user_id = auth.uid() and g.clip is null and g.created_at > now() - interval '1 hour'
                  and g.gkey::text = split_part(storage.filename(name), '.', 1))
  );
drop policy if exists "clip delete own" on storage.objects;
create policy "clip delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);

-- 6. Droit à l'effacement : le joueur supprime lui-même son compte (parties anonymisées, profil et accès supprimés)
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'auth'; end if;
  update public.games set user_id = null, clip = null where user_id = uid;
  update public.profiles set referred_by = null where referred_by = uid;
  delete from public.profiles where id = uid;
  delete from auth.users where id = uid;
end $$;
grant execute on function public.delete_my_account() to authenticated;

-- 7. Classement : joueurs exclus retirés
create or replace function public.leaderboard(p_side text, p_period text)
returns table (rank bigint, pseudo text, score bigint, stage int, tenue text, played_at timestamptz)
language sql stable security definer set search_path = public as $$
  with g as (
    select distinct on (gm.user_id) gm.user_id, gm.score, gm.stage, gm.tenue, gm.created_at
    from public.games gm join public.profiles pr on pr.id = gm.user_id and not pr.banned
    where gm.side = p_side
      and gm.created_at >= case p_period when 'day' then date_trunc('day', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris'
                                         when 'week' then now() - interval '7 days' else '-infinity'::timestamptz end
    order by gm.user_id, gm.score desc, gm.created_at
  )
  select rank() over (order by g.score desc, g.created_at), p.pseudo, g.score, g.stage, g.tenue, g.created_at
  from g join public.profiles p on p.id = g.user_id
  order by g.score desc, g.created_at
  limit 50;
$$;

-- 8. Les fonctions internes ne sont pas appelables depuis le navigateur
revoke execute on function public.gen_pseudo(), public.on_new_user(), public.games_guard(), public.visits_guard() from public, anon, authenticated;
-- Les fonctions réservées aux joueurs connectés ne sont pas appelables anonymement
revoke execute on function public.set_news_consent(boolean), public.claim_referral(text), public.claim_game(uuid), public.set_game_clip(uuid,text),
  public.reroll_pseudo(), public.my_rank(text,text), public.admin_set_banned(uuid,boolean), public.delete_my_account() from public, anon;
grant execute on function public.set_news_consent(boolean), public.claim_referral(text), public.claim_game(uuid), public.set_game_clip(uuid,text),
  public.reroll_pseudo(), public.my_rank(text,text), public.admin_set_banned(uuid,boolean), public.delete_my_account() to authenticated;
revoke execute on function public.leaderboard(text,text) from public;
grant execute on function public.leaderboard(text,text) to anon, authenticated;
