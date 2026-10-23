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

-- ============ Mur des joueurs (commentaires) ============
create table if not exists public.comments (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 2 and 280),
  side text check (side in ('bloc','police')),
  hidden boolean not null default false,
  reports int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists comments_recent on public.comments (created_at desc) where not hidden;
create table if not exists public.comment_reports (
  comment_id bigint references public.comments(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (comment_id, user_id)
);
alter table public.comments enable row level security;
alter table public.comment_reports enable row level security;
revoke all on public.comments, public.comment_reports from anon, authenticated;
drop policy if exists "admin comments" on public.comments;
create policy "admin comments" on public.comments for select to authenticated using (public.is_admin());
grant select on public.comments to authenticated;

-- Normalisation pour le filtre : minuscules, sans accents, lettres répétées réduites, chiffres « leet » remplacés
create or replace function public.norm_text(t text) returns text
language sql immutable set search_path = public as $$
  select regexp_replace(
           translate(lower(t), 'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ013457@$', 'aaaaaaceeeeiiiinooooouuuuyyoaoieastas'),
           '(.)\1+', '\1', 'g');
$$;

-- Liste de termes refusés (insultes, propos haineux, appels à la violence). Complétable par l'administrateur.
create table if not exists public.banned_terms (term text primary key);
alter table public.banned_terms enable row level security;
revoke all on public.banned_terms from anon, authenticated;
delete from public.banned_terms where term in ('viol','suicide');
insert into public.banned_terms (term) values
 ('connard'),('connasse'),('salope'),('pute'),('putain de'),('encule'),('enfoire'),('batard'),('nique'),('niquer'),('ntm'),('fdp'),('fils de p'),
 ('pd'),('pede'),('tapette'),('gouine'),('negre'),('negro'),('bougnoul'),('bicot'),('raton'),('youpin'),('feuj'),('chinetoque'),('bamboula'),
 ('sale arabe'),('sale noir'),('sale juif'),('sale blanc'),('sale flic'),('nazi'),('hitler'),('heil'),('sieg'),
 ('tuer les'),('tuez'),('buter les'),('butez'),('egorger'),('mort aux'),('crever les'),('a mort'),('acab'),('1312'),
 ('violer'),('violez'),('pedo'),('pedophile'),('jihad'),('attentat')
on conflict do nothing;

create or replace function public.has_banned(t text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.banned_terms b
    where (' ' || regexp_replace(public.norm_text(t), '[^a-z0-9]+', ' ', 'g') || ' ')
          like ('% ' || btrim(regexp_replace(public.norm_text(b.term), '[^a-z0-9]+', ' ', 'g')) || ' %')
  );
$$;

-- Publier : joueur vérifié non exclu, sans lien, sans terme refusé, 30 s entre deux messages, 20 par jour
create or replace function public.post_comment(p_body text, p_side text) returns bigint
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); b text; nid bigint;
begin
  if uid is null then raise exception 'auth'; end if;
  if exists (select 1 from public.profiles where id = uid and banned) then raise exception 'banned'; end if;
  b := btrim(regexp_replace(regexp_replace(coalesce(p_body,''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  if char_length(b) < 2 or char_length(b) > 280 then raise exception 'length'; end if;
  if b ~* '(https?://|www\.|[a-z0-9-]+\.(com|fr|net|org|io|ly|gg|me|tv|co|xyz|info|biz|ru|be|ch)\b|@[a-z0-9_]{3,})' then raise exception 'link'; end if;
  if public.has_banned(b) then raise exception 'banned_term'; end if;
  if exists (select 1 from public.comments where user_id = uid and created_at > now() - interval '30 seconds') then raise exception 'rate_limited'; end if;
  if (select count(*) from public.comments where user_id = uid and created_at > now() - interval '1 day') >= 20 then raise exception 'rate_limited'; end if;
  insert into public.comments (user_id, body, side) values (uid, b, case when p_side in ('bloc','police') then p_side end) returning id into nid;
  return nid;
end $$;

-- Lire le mur : messages visibles, auteurs non exclus, pseudo et meilleur score (jamais l'e-mail)
create or replace function public.wall(p_before timestamptz default null, p_limit int default 30)
returns table (id bigint, pseudo text, body text, side text, best bigint, created_at timestamptz, mine boolean)
language sql stable security definer set search_path = public as $$
  select c.id, p.pseudo, c.body, c.side,
         (select max(g.score) from public.games g where g.user_id = c.user_id and g.side = coalesce(c.side, g.side)),
         c.created_at, c.user_id = auth.uid()
  from public.comments c join public.profiles p on p.id = c.user_id and not p.banned
  where not c.hidden and (p_before is null or c.created_at < p_before)
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 50);
$$;

-- Signaler : une fois par joueur et par message ; masqué automatiquement à 3 signalements
create or replace function public.report_comment(p_id bigint) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'auth'; end if;
  insert into public.comment_reports (comment_id, user_id) values (p_id, uid) on conflict do nothing;
  if found then
    update public.comments set reports = reports + 1, hidden = hidden or reports + 1 >= 3 where id = p_id;
  end if;
end $$;

-- Supprimer son propre message
create or replace function public.delete_my_comment(p_id bigint) returns void
language sql security definer set search_path = public as $$
  delete from public.comments where id = p_id and user_id = auth.uid();
$$;

-- Modération (administrateur)
create or replace function public.admin_moderate_comment(p_id bigint, p_action text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_action = 'hide' then update public.comments set hidden = true where id = p_id;
  elsif p_action = 'show' then update public.comments set hidden = false, reports = 0 where id = p_id; delete from public.comment_reports where comment_id = p_id;
  elsif p_action = 'delete' then delete from public.comments where id = p_id;
  else raise exception 'action'; end if;
end $$;

create or replace function public.admin_add_banned_term(p_term text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  insert into public.banned_terms (term) values (lower(btrim(p_term))) on conflict do nothing;
end $$;

revoke execute on function public.norm_text(text), public.has_banned(text) from public, anon, authenticated;
revoke execute on function public.post_comment(text,text), public.report_comment(bigint), public.delete_my_comment(bigint),
  public.admin_moderate_comment(bigint,text), public.admin_add_banned_term(text) from public, anon;
grant execute on function public.post_comment(text,text), public.report_comment(bigint), public.delete_my_comment(bigint),
  public.admin_moderate_comment(bigint,text), public.admin_add_banned_term(text) to authenticated;
revoke execute on function public.wall(timestamptz,int) from public;
grant execute on function public.wall(timestamptz,int) to anon, authenticated;

-- La suppression de compte efface aussi les messages (déjà assuré par « on delete cascade »)
