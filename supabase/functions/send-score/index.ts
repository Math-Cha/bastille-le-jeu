// BASTILLE — envoie au joueur connecté l'e-mail de sa partie (score, vidéo, partage, parrainage) via Brevo.
// Secrets à définir dans Supabase (Edge Functions → Secrets) : BREVO_API_KEY, MAIL_FROM, SITE_URL
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Seules les pages du site (SITE_URL, et ALLOWED_ORIGINS séparées par des virgules) peuvent appeler la fonction
const ORIGINS = [Deno.env.get("SITE_URL") || "", ...(Deno.env.get("ALLOWED_ORIGINS") || "").split(",")]
  .map((u) => { try { return new URL(u.trim()).origin; } catch { return ""; } }).filter(Boolean);
let CORS: Record<string, string> = {};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const fr = (n: number) => Math.round(n).toLocaleString("fr-FR");

Deno.serve(async (req) => {
  const origin = req.headers.get("Origin") || "";
  CORS = {
    "Access-Control-Allow-Origin": ORIGINS.includes(origin) ? origin : (ORIGINS[0] || "null"),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (!ORIGINS.includes(origin)) return json({ error: "origin" }, 403);
  if (Number(req.headers.get("content-length") || 0) > 2048) return json({ error: "too_large" }, 413);
  if (req.method !== "POST") return json({ error: "method" }, 405);
  try {
    const URL_ = Deno.env.get("SUPABASE_URL")!;
    const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const BREVO = Deno.env.get("BREVO_API_KEY");
    const FROM = Deno.env.get("MAIL_FROM");
    const SITE = (Deno.env.get("SITE_URL") || "").replace(/\/$/, "");
    if (!BREVO || !FROM || !SITE) return json({ error: "not_configured" }, 503);

    const auth = req.headers.get("Authorization") || "";
    const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: auth } } });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user || !user.email) return json({ error: "auth" }, 401);

    const { gkey } = await req.json().catch(() => ({}));
    if (typeof gkey !== "string" || !/^[0-9a-f-]{36}$/i.test(gkey)) return json({ error: "gkey" }, 400);

    const db = createClient(URL_, SERVICE);
    const { data: game } = await db.from("games").select("*").eq("gkey", gkey).eq("user_id", user.id).maybeSingle();
    if (!game) return json({ error: "not_found" }, 404);
    if (game.mailed_at) return json({ error: "already_sent" }, 409);

    // au plus 5 e-mails par heure et par joueur
    const since = new Date(Date.now() - 3600_000).toISOString();
    const { count } = await db.from("games").select("id", { count: "exact", head: true }).eq("user_id", user.id).gte("mailed_at", since);
    if ((count || 0) >= 5) return json({ error: "rate_limited" }, 429);

    const { data: prof } = await db.from("profiles").select("ref_code").eq("id", user.id).maybeSingle();
    const ref = prof?.ref_code || "";
    const invite = `${SITE}/?ref=${ref}`;
    const clipPage = game.clip ? `${SITE}/clip.html?v=${encodeURIComponent(game.clip)}&r=${ref}` : null;
    const bloc = game.side === "bloc";
    const scoreTxt = bloc ? `${fr(game.score)} €` : `${fr(game.score)} interpellations`;
    const shareUrl = clipPage || invite;
    const shareText = `J'ai fait ${scoreTxt} à BASTILLE (${bloc ? "Black Bloc" : "Police"}, étape ${game.stage}). À toi de jouer !`;
    const enc = encodeURIComponent;
    const btn = (href: string, label: string, bg: string, fg = "#fbf3e4") =>
      `<a href="${esc(href)}" style="display:inline-block;margin:4px 4px 0 0;padding:10px 14px;border-radius:10px;background:${bg};color:${fg};font:700 14px Arial,sans-serif;text-decoration:none">${label}</a>`;

    const html = `<!doctype html><html lang="fr"><body style="margin:0;background:#fbf3e4;font-family:Arial,sans-serif;color:#1d1230">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" style="max-width:520px;background:#fffaf1;border:3px solid #1d1230;border-radius:18px" cellpadding="0" cellspacing="0">
<tr><td style="background:#1d1230;border-radius:14px 14px 0 0;padding:18px 22px;color:#ffb830;font:900 28px Arial,sans-serif;letter-spacing:1px">BASTILLE</td></tr>
<tr><td style="padding:22px">
  <p style="margin:0 0 6px;font-size:14px;color:#3a2550">Ta dernière manif, côté ${bloc ? "Black Bloc" : "Police"}</p>
  <p style="margin:0 0 4px;font:900 30px Arial,sans-serif">${esc(scoreTxt)}</p>
  <p style="margin:0 0 16px;font-size:15px">Étape ${game.stage} · ${game.bosses} boss vaincu${game.bosses > 1 ? "s" : ""} · ${Math.floor(game.duration_s / 60)} min ${game.duration_s % 60} s</p>
  ${clipPage ? `<p style="margin:0 0 6px;font-weight:700">Ta vidéo (20 dernières secondes) :</p>${btn(clipPage, "▶ Voir et partager la vidéo", "#ff5a4e")}` : ""}
  <p style="margin:18px 0 6px;font-weight:700">Partage ton score :</p>
  ${btn(`https://twitter.com/intent/tweet?text=${enc(shareText)}&url=${enc(shareUrl)}`, "X", "#1d1230")}
  ${btn(`https://www.facebook.com/sharer/sharer.php?u=${enc(shareUrl)}`, "Facebook", "#2f5bff")}
  ${btn(`https://wa.me/?text=${enc(shareText + " " + shareUrl)}`, "WhatsApp", "#14b58a")}
  ${btn(`https://www.linkedin.com/sharing/share-offsite/?url=${enc(shareUrl)}`, "LinkedIn", "#3a2550")}
  <div style="margin:22px 0 0;padding:14px;border-radius:14px;background:#fbf3e4;border:2px dashed #1d1230">
    <p style="margin:0 0 6px;font-weight:700">Gagne des crédits : +200 par ami inscrit</p>
    <p style="margin:0 0 8px;font-size:14px">Transfère cet e-mail ou envoie ton lien. Chaque ami qui joue et vérifie son e-mail avec ton lien te rapporte 200 crédits (et 100 pour lui).</p>
    <p style="margin:0;font:700 14px Arial,sans-serif;word-break:break-all"><a href="${esc(invite)}" style="color:#2f5bff">${esc(invite)}</a></p>
  </div>
  <p style="margin:22px 0 0">${btn(SITE + "/", "REJOUER", "#ffb830", "#1d1230")}</p>
</td></tr></table>
<p style="font-size:11px;color:#6d6182;max-width:520px;margin:14px auto 0">Tu reçois cet e-mail parce que tu l'as demandé à la fin de ta partie sur BASTILLE, jeu satirique et fictif. <a href="${esc(SITE)}/confidentialite.html" style="color:#6d6182">Confidentialité</a></p>
</td></tr></table></body></html>`;

    const r = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "api-key": BREVO, "Content-Type": "application/json", accept: "application/json" },
      body: JSON.stringify({
        sender: { email: FROM, name: "BASTILLE" },
        to: [{ email: user.email }],
        subject: `Ton score BASTILLE : ${scoreTxt}`,
        htmlContent: html,
      }),
    });
    if (!r.ok) return json({ error: "mail_failed", status: r.status }, 502);
    await db.from("games").update({ mailed_at: new Date().toISOString() }).eq("id", game.id);
    return json({ ok: true });
  } catch (e) {
    return json({ error: "server", message: String(e) }, 500);
  }
});
