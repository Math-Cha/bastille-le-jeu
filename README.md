# BASTILLE — le jeu

Jeu satirique et fictif de la manif République–Bastille (HTML5, mobile d'abord).

- `index.html` : le jeu (vidéo de fin de partie, connexion par code, classement)
- `admin.html` : tableau de bord (connexion par code, réservé aux e-mails de la table `admins`)
- `clip.html` : page de partage d'une vidéo
- `confidentialite.html` : politique de confidentialité
- `config.js` : URL et clé **anon public** Supabase, adresse de contact
- `account.js`, `rec.js` : compte joueur, statistiques, vidéo
- `vendor/` : bibliothèques hébergées localement (supabase-js 2.45.4, Chart.js 4.4.1)
- `supabase/schema.sql` : tables, règles de sécurité et fonctions (relançable)
- `supabase/functions/send-score` : envoi de l'e-mail de score (Brevo)
- `SECURITY.md` : données, contrôles de sécurité, risques résiduels, réglages
