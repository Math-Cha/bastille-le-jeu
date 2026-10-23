# BASTILLE — sécurité et données

Site statique (GitHub Pages) + Supabase (base PostgreSQL, authentification, stockage) + une fonction serveur (envoi d'e-mail via Brevo).
Principe : **le navigateur n'est jamais digne de confiance**. Tout contrôle d'accès est fait dans la base (Row Level Security, droits par colonne, fonctions vérifiées), jamais seulement dans le code JavaScript.

## Données collectées
| Donnée | Où | Qui peut lire | Durée |
|---|---|---|---|
| Visites (identifiant aléatoire, appareil, site d'origine) | `visits` | administrateur | 25 mois |
| Parties (score, étape, tenue, armes, durée) | `games` | le joueur (les siennes), administrateur | 25 mois |
| E-mail vérifié, pseudo, consentement newsletter, parrainage | `profiles` + `auth.users` | le joueur (le sien), administrateur | jusqu'à suppression, 3 ans max |
| Messages du mur (texte, camp) | `comments` | public via `wall()` (pseudo, jamais l'e-mail), administrateur | jusqu'à suppression par l'auteur, l'admin ou avec le compte |
| Vidéo des 20 dernières secondes | stockage `clips` (public par lien) | toute personne ayant le lien | 12 mois |

Aucune donnée bancaire, aucun mot de passe (connexion par code à usage unique), aucune géolocalisation, aucun traceur publicitaire.

## Contrôles en place
- **Clés** : seule la clé `anon` (publique par conception) est dans le site. La clé `service_role` n'existe que dans les secrets de la fonction serveur. Aucun secret dans le dépôt.
- **Droits par défaut supprimés** : `revoke all` sur toutes les tables, puis droits minimaux. Un visiteur anonyme ne peut que **ajouter** une visite ou une partie, et seulement certaines colonnes (impossible de fixer `user_id`, `clip`, `mailed_at`, `created_at`).
- **Row Level Security** sur toutes les tables : un joueur ne lit que ses propres données ; l'administrateur est défini par la table `admins` (vérifiée côté base).
- **Écritures sensibles uniquement via des fonctions contrôlées** : consentement, parrainage (une fois par filleul, dans les 24 h, pas soi-même, sans plafond par parrain), rattachement d'une partie (1 h, si sans propriétaire), vidéo (sa partie, son dossier), changement de pseudo, exclusion du classement (admin), suppression de compte.
- **Anti-triche et anti-spam** (déclencheurs en base) : scores, étapes et boss plafonnés selon la durée de la partie ; 1 partie / 5 s et 300 / jour par visiteur ; 50 visites / jour ; 5 e-mails de score / heure par joueur.
- **Classement** : seuls les joueurs à l'e-mail vérifié y figurent ; pseudos générés (aucun texte libre, donc pas de contenu injurieux) ; l'administrateur peut exclure un tricheur.
- **Vidéos** : dépôt seulement par un joueur connecté, pour sa propre partie récente, 15 Mo max, MP4/WebM uniquement.
- **Fonction e-mail** : jeton du joueur vérifié, origine du site obligatoire, corps limité à 2 Ko, contenu échappé, partie appartenant au joueur, envoi unique par partie.
- **Pages** : Content-Security-Policy stricte (scripts autorisés par empreinte SHA-256, connexions limitées au projet Supabase), aucune ressource tierce hormis Google Fonts, bibliothèques hébergées sur le site (pas de CDN), affichage des données uniquement via `textContent` (pas d'injection HTML), `referrer` limité, page admin non indexée.
- **Mur des joueurs** : écriture réservée aux joueurs vérifiés non exclus, via une fonction contrôlée (2–280 caractères, caractères de contrôle retirés, aucun lien ni mention, termes interdits normalisés — accents, majuscules, chiffres « leet », lettres répétées —, 1 message / 30 s et 20 / jour) ; lecture publique uniquement par `wall()` ; signalement unique par joueur, masquage automatique à 3 signalements ; modération admin (masquer, réafficher, supprimer, ajouter un terme). Obligation d'hébergeur (LCEN) : retirer promptement un contenu illicite signalé.
- **Droit à l'effacement** : bouton « Supprimer mon compte » dans le jeu (profil, accès et vidéos effacés, parties anonymisées).

## Risques résiduels (assumés et suivis)
- **Scores falsifiables dans les limites de vraisemblance** : un jeu exécuté dans le navigateur ne peut pas prouver ses scores. Les plafonds rendent la triche grossière impossible ; la triche fine est gérée par l'exclusion du classement depuis l'admin.
- **Spam d'inscriptions par code** : limité par Supabase (envois de codes par heure). Recommandé dès que le trafic monte : CAPTCHA Cloudflare Turnstile sur la connexion (réglage Supabase, sans changement de code majeur).
- **Les vidéos sont publiques par lien** (c'est le but du partage) ; le contenu ne peut être qu'une vidéo, déposée par un joueur vérifié, rattachée à une partie.
- **Pas d'en-têtes HTTP personnalisés sur GitHub Pages** (pas de `frame-ancestors`) : risque de mise en cadre de la page, sans action sensible possible depuis le jeu.

## Réglages Supabase à appliquer (checklist)
1. Région UE (Paris). Exécuter `supabase/schema.sql` (relançable sans risque).
2. Authentication → Providers → Email : connexion par code activée, **expiration du code 10 min**, longueur 6.
3. Authentication → Email Templates → « Magic Link » : afficher le code `{{ .Token }}` (et non un lien).
4. Authentication → SMTP : Brevo (expéditeur vérifié) — le SMTP intégré de Supabase est limité à quelques e-mails par heure.
5. Authentication → URL Configuration : Site URL = adresse du site ; Redirect URLs = adresse du site uniquement.
6. Authentication → Rate Limits : laisser les valeurs par défaut ou plus strictes.
7. Edge Functions → `send-score` déployée avec vérification JWT ; secrets `BREVO_API_KEY`, `MAIL_FROM`, `SITE_URL`.
8. Table `admins` : uniquement les e-mails administrateurs.
9. Sauvegardes : sur l'offre gratuite, exporter la base chaque mois (Database → Backups) ; passer en Pro pour les sauvegardes quotidiennes si le jeu décolle.

## Exploitation
- **Rotation** : si la clé `service_role` ou la clé Brevo fuite, la régénérer immédiatement (Supabase → API, Brevo → SMTP & API) et mettre à jour les secrets de la fonction.
- **Purge (mensuelle)** : `delete from visits where created_at < now() - interval '25 months'; update games set user_id = null, clip = null where created_at < now() - interval '25 months';` et suppression des vidéos de plus de 12 mois (Storage).
- **Incident** : suspendre le site (désactiver GitHub Pages) et révoquer la clé `anon` si besoin ; la base reste intacte.
