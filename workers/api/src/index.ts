import {
  authenticate,
  authenticateOptional,
  constantTimeEqual,
  generateOtpCode,
  hashOtp,
  jwtExpiresAt,
  normalizeEmail,
  otpExpiresAt,
  randomToken,
  requireSecret,
  signJwt
} from "./auth";
import { AppError, json, jsonError, optionsResponse, readJsonObject } from "./http";
import { parseSpellInput, rowToSpell, rowsToSpells, type SpellRow } from "./spells";

type OtpRow = {
  id: string;
  email: string;
  code_hash: string;
  salt: string;
  expires_at: string;
  consumed_at: string | null;
  created_at: string;
};

type SpellbookSecrets = {
  SPELLBOOK_JWT_SECRET?: string;
  RESEND_API_KEY?: string;
  RESEND_FROM_EMAIL?: string;
};

type SpellbookConfig = {
  SPELLBOOK_WEB_URL?: string;
  SPELLBOOK_MACOS_DEEPLINK_SCHEME?: string;
};

type SpellbookEnv = Env & SpellbookSecrets & SpellbookConfig;

const DEFAULT_SPELLBOOK_WEB_URL = "https://spellbook.raddus.dev/";
const DEFAULT_SPELLBOOK_MACOS_SCHEME = "spellbook";

export default {
  async fetch(request: Request, env: SpellbookEnv, ctx: ExecutionContext): Promise<Response> {
    if (request.method === "OPTIONS") {
      return optionsResponse();
    }

    const url = new URL(request.url);
    const requestId = crypto.randomUUID();

    try {
      const response = await route(request, env, ctx, url);
      return response;
    } catch (error) {
      if (error instanceof AppError) {
        if (error.status >= 500) {
          logError({ error, path: url.pathname, requestId, safeMessage: error.message });
        }
        return jsonError(error.message, error.status, requestId);
      }

      const safeError = classifyUnexpectedError(error);
      logError({ error, path: url.pathname, requestId, safeMessage: safeError.message });
      return jsonError(safeError.message, safeError.status, requestId);
    }
  }
} satisfies ExportedHandler<SpellbookEnv>;

async function route(request: Request, env: SpellbookEnv, ctx: ExecutionContext, url: URL): Promise<Response> {
  if (request.method === "GET" && url.pathname === "/api/health") {
    return json({ ok: true, product: "Raddus Spellbook" });
  }

  const dynamicLinkMatch = url.pathname.match(/^\/open\/([^/]+)$/);
  if (request.method === "GET" && dynamicLinkMatch?.[1]) {
    return redirectToSpell(request, env, decodeURIComponent(dynamicLinkMatch[1]));
  }

  if (request.method === "POST" && url.pathname === "/api/auth/request-otp") {
    return requestOtp(request, env, ctx);
  }

  if (request.method === "POST" && url.pathname === "/api/auth/verify-otp") {
    return verifyOtp(request, env);
  }

  if (request.method === "GET" && url.pathname === "/api/spells/public") {
    const user = await authenticateOptional(request, env.SPELLBOOK_JWT_SECRET);
    return listPublicSpells(env, url, user?.email ?? null);
  }

  if (request.method === "GET" && url.pathname === "/api/spells/mine") {
    const user = await authenticate(request, env.SPELLBOOK_JWT_SECRET);
    return listMine(env, user.email);
  }

  if (request.method === "POST" && url.pathname === "/api/spells") {
    const user = await authenticate(request, env.SPELLBOOK_JWT_SECRET);
    return upsertSpell(request, env, user.email);
  }

  const starMatch = url.pathname.match(/^\/api\/spells\/([^/]+)\/star$/);
  if ((request.method === "POST" || request.method === "DELETE") && starMatch?.[1]) {
    const user = await authenticate(request, env.SPELLBOOK_JWT_SECRET);
    return setSpellStar(env, decodeURIComponent(starMatch[1]), user.email, request.method === "POST");
  }

  const spellMatch = url.pathname.match(/^\/api\/spells\/([^/]+)$/);
  if (request.method === "GET" && spellMatch?.[1]) {
    const user = await authenticateOptional(request, env.SPELLBOOK_JWT_SECRET);
    return getPublicSpell(env, decodeURIComponent(spellMatch[1]), user?.email ?? null);
  }

  if (request.method === "DELETE" && spellMatch?.[1]) {
    const user = await authenticate(request, env.SPELLBOOK_JWT_SECRET);
    return deleteSpell(env, decodeURIComponent(spellMatch[1]), user.email);
  }

  return jsonError("That Spellbook endpoint was not found.", 404);
}

function redirectToSpell(request: Request, env: SpellbookEnv, spellId: string): Response {
  const normalizedSpellId = spellId.trim();
  if (!normalizedSpellId) {
    throw new AppError("Spell not found.", 404);
  }

  const location = requestComesFromMacOS(request)
    ? macOSSpellURL(env, normalizedSpellId)
    : webSpellURL(env, normalizedSpellId);

  return Response.redirect(location, 302);
}

function requestComesFromMacOS(request: Request): boolean {
  const userAgent = request.headers.get("User-Agent") ?? "";
  return /Macintosh|Mac OS X/i.test(userAgent)
    && !/iPhone|iPad|iPod|Mobile/i.test(userAgent);
}

function macOSSpellURL(env: SpellbookEnv, spellId: string): string {
  const scheme = env.SPELLBOOK_MACOS_DEEPLINK_SCHEME || DEFAULT_SPELLBOOK_MACOS_SCHEME;
  return `${scheme}://spell/${encodeURIComponent(spellId)}`;
}

function webSpellURL(env: SpellbookEnv, spellId: string): string {
  const url = new URL(env.SPELLBOOK_WEB_URL || DEFAULT_SPELLBOOK_WEB_URL);
  url.pathname = `/spell/${encodeURIComponent(spellId)}`;
  url.search = "";
  url.hash = "";
  return url.toString();
}

async function requestOtp(request: Request, env: SpellbookEnv, ctx: ExecutionContext): Promise<Response> {
  const resendApiKey = requireSecret(env.RESEND_API_KEY, "Email delivery is not configured.");
  const resendFromEmail = requireSecret(env.RESEND_FROM_EMAIL, "Email delivery is not configured.");
  const jwtSecret = requireSecret(env.SPELLBOOK_JWT_SECRET, "Authentication is not configured.");
  const db = requireDatabase(env);
  const body = await readJsonObject(request);
  const email = normalizeEmail(body.email);
  const code = generateOtpCode();
  const salt = randomToken(18);
  const now = new Date().toISOString();
  const expiresAt = otpExpiresAt();
  const codeHash = await hashOtp(email, code, salt, jwtSecret);

  await db.prepare(
    `INSERT INTO otp_challenges (id, email, code_hash, salt, expires_at, consumed_at, created_at)
     VALUES (?, ?, ?, ?, ?, NULL, ?)`
  )
    .bind(crypto.randomUUID(), email, codeHash, salt, expiresAt, now)
    .run();

  await sendOtpEmail({ email, code, resendApiKey, resendFromEmail });
  ctx.waitUntil(deleteExpiredOtpChallenges(env));

  return json({ ok: true, expiresAt });
}

async function verifyOtp(request: Request, env: SpellbookEnv): Promise<Response> {
  const jwtSecret = requireSecret(env.SPELLBOOK_JWT_SECRET, "Authentication is not configured.");
  const db = requireDatabase(env);
  const body = await readJsonObject(request);
  const email = normalizeEmail(body.email);
  const code = typeof body.code === "string" ? body.code.trim() : "";

  if (!/^\d{6}$/.test(code)) {
    throw new AppError("Enter the six-digit code.", 400);
  }

  const challenge = await db.prepare(
    `SELECT id, email, code_hash, salt, expires_at, consumed_at, created_at
     FROM otp_challenges
     WHERE email = ? AND consumed_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1`
  )
    .bind(email)
    .first<OtpRow>();

  if (!challenge || new Date(challenge.expires_at).getTime() <= Date.now()) {
    throw new AppError("The code is invalid or expired.", 400);
  }

  const candidateHash = await hashOtp(email, code, challenge.salt, jwtSecret);
  const validCode = await constantTimeEqual(candidateHash, challenge.code_hash);
  if (!validCode) {
    throw new AppError("The code is invalid or expired.", 400);
  }

  await db.prepare("UPDATE otp_challenges SET consumed_at = ? WHERE id = ?")
    .bind(new Date().toISOString(), challenge.id)
    .run();

  const session = await signJwt(email, jwtSecret);
  return json({ token: session.token, email, expiresAt: session.expiresAt });
}

async function listPublicSpells(env: SpellbookEnv, url: URL, viewerEmail: string | null): Promise<Response> {
  const db = requireDatabase(env);
  const limit = parseLimit(url.searchParams.get("limit"));
  const result = await db.prepare(
    `SELECT id, name, description, trigger, file, content, version, tags_json, owner_email,
            published, created_at, updated_at, published_at,
            (SELECT COUNT(*) FROM spell_stars WHERE spell_stars.spell_id = spells.id) AS star_count,
            CASE
              WHEN ? IS NOT NULL AND EXISTS (
                SELECT 1 FROM spell_stars
                WHERE spell_stars.spell_id = spells.id AND spell_stars.owner_email = ?
              )
              THEN 1
              ELSE 0
            END AS starred_by_viewer
     FROM spells
     WHERE published = 1
     ORDER BY updated_at DESC
     LIMIT ?`
  )
    .bind(viewerEmail, viewerEmail, limit)
    .all<SpellRow>();

  return json({ spells: rowsToSpells(result.results) });
}

async function listMine(env: SpellbookEnv, ownerEmail: string): Promise<Response> {
  const db = requireDatabase(env);
  const result = await db.prepare(
    `SELECT id, name, description, trigger, file, content, version, tags_json, owner_email,
            published, created_at, updated_at, published_at,
            (SELECT COUNT(*) FROM spell_stars WHERE spell_stars.spell_id = spells.id) AS star_count,
            CASE
              WHEN EXISTS (
                SELECT 1 FROM spell_stars
                WHERE spell_stars.spell_id = spells.id AND spell_stars.owner_email = ?
              )
              THEN 1
              ELSE 0
            END AS starred_by_viewer
     FROM spells
     WHERE owner_email = ?
     ORDER BY updated_at DESC`
  )
    .bind(ownerEmail, ownerEmail)
    .all<SpellRow>();

  return json({ spells: rowsToSpells(result.results) });
}

async function getPublicSpell(env: SpellbookEnv, uid: string, viewerEmail: string | null): Promise<Response> {
  const spell = await findSpellByUID(env, uid, viewerEmail);
  if (!spell || spell.published !== 1) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: rowToSpell(spell) });
}

async function upsertSpell(request: Request, env: SpellbookEnv, ownerEmail: string): Promise<Response> {
  const db = requireDatabase(env);
  const input = parseSpellInput(await readJsonObject(request));
  const now = new Date().toISOString();

  if (input.uid) {
    const existing = await findSpellByUID(env, input.uid);
    if (!existing) {
      throw new AppError("Spell not found.", 404);
    }

    if (existing.owner_email !== ownerEmail) {
      throw new AppError("Only the creator can update this spell.", 403);
    }

    await db.prepare(
      `UPDATE spells
       SET name = ?, description = ?, trigger = ?, file = ?, content = ?, tags_json = ?, version = version + 1, published = 1, updated_at = ?,
           published_at = COALESCE(published_at, ?)
       WHERE id = ?`
    )
      .bind(
        input.name,
        input.description,
        input.trigger,
        input.file,
        input.content,
        JSON.stringify(input.tags),
        now,
        now,
        input.uid
      )
      .run();

    const updated = await findSpellByUID(env, input.uid, ownerEmail);
    if (!updated) {
      throw new AppError("Spell not found.", 404);
    }

    return json({ spell: rowToSpell(updated) });
  }

  const uid = crypto.randomUUID();
  await db.prepare(
    `INSERT INTO spells (
       id, name, description, trigger, file, content, version, tags_json, owner_email,
       published, created_at, updated_at, published_at
     )
     VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, 1, ?, ?, ?)`
  )
    .bind(
      uid,
      input.name,
      input.description,
      input.trigger,
      input.file,
      input.content,
      JSON.stringify(input.tags),
      ownerEmail,
      now,
      now,
      now
    )
    .run();

  const created = await findSpellByUID(env, uid, ownerEmail);
  if (!created) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: rowToSpell(created) }, { status: 201 });
}

async function deleteSpell(env: SpellbookEnv, uid: string, ownerEmail: string): Promise<Response> {
  const db = requireDatabase(env);
  const existing = await findSpellByUID(env, uid);
  if (!existing) {
    throw new AppError("Spell not found.", 404);
  }

  if (existing.owner_email !== ownerEmail) {
    throw new AppError("Only the creator can delete this spell", 403);
  }

  await db.batch([
    db.prepare("DELETE FROM spell_stars WHERE spell_id = ?").bind(uid),
    db.prepare("DELETE FROM spells WHERE id = ?").bind(uid)
  ]);
  return json({ ok: true });
}

async function setSpellStar(env: SpellbookEnv, uid: string, ownerEmail: string, starred: boolean): Promise<Response> {
  const db = requireDatabase(env);
  const existing = await findSpellByUID(env, uid, ownerEmail);
  if (!existing) {
    throw new AppError("Spell not found.", 404);
  }

  if (starred) {
    await db.prepare(
      `INSERT OR IGNORE INTO spell_stars (spell_id, owner_email, created_at)
       VALUES (?, ?, ?)`
    )
      .bind(uid, ownerEmail, new Date().toISOString())
      .run();
  } else {
    await db.prepare("DELETE FROM spell_stars WHERE spell_id = ? AND owner_email = ?")
      .bind(uid, ownerEmail)
      .run();
  }

  const updated = await findSpellByUID(env, uid, ownerEmail);
  if (!updated) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: rowToSpell(updated) });
}

async function findSpellByUID(env: SpellbookEnv, uid: string, viewerEmail: string | null = null): Promise<SpellRow | null> {
  const db = requireDatabase(env);
  return db.prepare(
    `SELECT id, name, description, trigger, file, content, version, tags_json, owner_email,
            published, created_at, updated_at, published_at,
            (SELECT COUNT(*) FROM spell_stars WHERE spell_stars.spell_id = spells.id) AS star_count,
            CASE
              WHEN ? IS NOT NULL AND EXISTS (
                SELECT 1 FROM spell_stars
                WHERE spell_stars.spell_id = spells.id AND spell_stars.owner_email = ?
              )
              THEN 1
              ELSE 0
            END AS starred_by_viewer
     FROM spells
     WHERE id = ?
     LIMIT 1`
  )
    .bind(viewerEmail, viewerEmail, uid)
    .first<SpellRow>();
}

async function deleteExpiredOtpChallenges(env: SpellbookEnv): Promise<void> {
  const db = requireDatabase(env);
  await db.prepare("DELETE FROM otp_challenges WHERE expires_at <= ? OR consumed_at IS NOT NULL")
    .bind(new Date().toISOString())
    .run();
}

async function sendOtpEmail({
  email,
  code,
  resendApiKey,
  resendFromEmail
}: {
  email: string;
  code: string;
  resendApiKey: string;
  resendFromEmail: string;
}): Promise<void> {
  let response: Response;

  try {
    response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${resendApiKey}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        from: resendFromEmail,
        to: [email],
        subject: "Your Spellbook sign-in code",
        text: `Your Spellbook sign-in code is ${code}. It expires in 10 minutes.`
      })
    });
  } catch (error) {
    console.error(
      JSON.stringify({
        message: "resend network failure",
        error: error instanceof Error ? error.message : String(error)
      })
    );
    throw new AppError("Email delivery could not reach Resend. Check network access and try again.", 502);
  }

  if (!response.ok) {
    console.error(JSON.stringify({ message: "resend send failed", status: response.status }));
    if (response.status === 401 || response.status === 403) {
      throw new AppError("Email delivery is not authorized. Check the Resend API key.", 503);
    }

    if (response.status === 400 || response.status === 422) {
      throw new AppError("Email delivery rejected the sender or recipient. Check the Resend from address.", 503);
    }

    throw new AppError("Email delivery is unavailable right now. Try again in a moment.", 502);
  }
}

function parseLimit(value: string | null): number {
  if (!value) {
    return 100;
  }

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    return 100;
  }

  return Math.min(parsed, 100);
}

function requireDatabase(env: SpellbookEnv): D1Database {
  if (!env.DB) {
    throw new AppError("Spellbook database is not configured. Add the D1 DB binding and redeploy the Worker.", 503);
  }

  return env.DB;
}

function classifyUnexpectedError(error: unknown): AppError {
  const message = error instanceof Error ? error.message : String(error);

  if (/no such table|no such column/i.test(message)) {
    return new AppError("Spellbook database schema and API deployment are out of sync. Apply the remote D1 migrations, then redeploy the Worker.", 503);
  }

  if (/SQLITE_ERROR|D1_ERROR/i.test(message)) {
    return new AppError("Spellbook database request failed. Check the Worker logs with the request ID.", 503);
  }

  if (/database.*not found|database_id|D1 database/i.test(message)) {
    return new AppError("Spellbook could not reach its D1 database. Check the D1 database_id and redeploy the Worker.", 503);
  }

  return new AppError("The Spellbook API hit an unexpected problem. Check the Worker logs with the request ID.", 500);
}

function logError({
  error,
  path,
  requestId,
  safeMessage
}: {
  error: unknown;
  path: string;
  requestId: string;
  safeMessage: string;
}): void {
  console.error(
    JSON.stringify({
      message: "request failed",
      requestId,
      path,
      safeMessage,
      error: error instanceof Error ? error.message : String(error)
    })
  );
}
