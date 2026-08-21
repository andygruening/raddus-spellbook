import {
  authenticateOptionalUser,
  authenticateUser,
  constantTimeEqual,
  ensureUser,
  generateOtpCode,
  hashOtp,
  normalizeEmail,
  requireAdminUser,
  requireSecret,
  randomToken,
  signJwt
} from "./auth";
import { requireDatabase, type SpellbookEnv } from "./db";
import { AppError, json, jsonError, optionsResponse, readJsonObject } from "./http";
import {
  createPack,
  getPackDraft,
  getPackVersion,
  listMyPacks,
  listPublicPacks,
  submitPackDraft,
  updatePackDraft
} from "./packs";
import {
  listReviewQueue,
  parseReviewVersion,
  reviewPack,
  reviewRule
} from "./reviews";
import {
  createRule,
  getLatestPublicRule,
  getRuleDraft,
  getRuleVersion,
  listMyRules,
  listPublicRules,
  submitRuleDraft,
  updateRuleDraft
} from "./rules";
import {
  deleteSpell,
  getPublicSpell,
  getPublicSpellVersion,
  listMySpells,
  listPublicSpells,
  setSpellStar,
  upsertSpell
} from "./spells";

type OtpRow = {
  id: string;
  email: string;
  code_hash: string;
  salt: string;
  expires_at: string;
  consumed_at: string | null;
  created_at: string;
};

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
      return await route(request, env, ctx, url);
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

  if (request.method === "GET" && url.pathname === "/api/rules/public") {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return listPublicRules(env, url, user?.email ?? null);
  }

  if (request.method === "GET" && url.pathname === "/api/rules/mine") {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return listMyRules(env, user);
  }

  if (request.method === "POST" && url.pathname === "/api/rules") {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return createRule(request, env, user);
  }

  const ruleDraftMatch = url.pathname.match(/^\/api\/rules\/([^/]+)\/draft$/);
  if (ruleDraftMatch?.[1]) {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    if (request.method === "GET") {
      return getRuleDraft(env, user, decodeURIComponent(ruleDraftMatch[1]));
    }
    if (request.method === "PATCH") {
      return updateRuleDraft(request, env, user, decodeURIComponent(ruleDraftMatch[1]));
    }
  }

  const ruleSubmitMatch = url.pathname.match(/^\/api\/rules\/([^/]+)\/submit$/);
  if (request.method === "POST" && ruleSubmitMatch?.[1]) {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return submitRuleDraft(env, user, decodeURIComponent(ruleSubmitMatch[1]));
  }

  const ruleVersionMatch = url.pathname.match(/^\/api\/rules\/([^/]+)\/versions\/(\d+)$/);
  if (request.method === "GET" && ruleVersionMatch?.[1] && ruleVersionMatch?.[2]) {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return getRuleVersion(
      env,
      decodeURIComponent(ruleVersionMatch[1]),
      Number(ruleVersionMatch[2]),
      user?.email ?? null
    );
  }

  const ruleMatch = url.pathname.match(/^\/api\/rules\/([^/]+)$/);
  if (request.method === "GET" && ruleMatch?.[1]) {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return getLatestPublicRule(env, decodeURIComponent(ruleMatch[1]), user?.email ?? null);
  }

  if (request.method === "GET" && url.pathname === "/api/packs/public") {
    return listPublicPacks(env, url);
  }

  if (request.method === "GET" && url.pathname === "/api/packs/mine") {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return listMyPacks(env, user);
  }

  if (request.method === "POST" && url.pathname === "/api/packs") {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return createPack(request, env, user);
  }

  const packDraftMatch = url.pathname.match(/^\/api\/packs\/([^/]+)\/draft$/);
  if (packDraftMatch?.[1]) {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    if (request.method === "GET") {
      return getPackDraft(env, user, decodeURIComponent(packDraftMatch[1]));
    }
    if (request.method === "PATCH") {
      return updatePackDraft(request, env, user, decodeURIComponent(packDraftMatch[1]));
    }
  }

  const packSubmitMatch = url.pathname.match(/^\/api\/packs\/([^/]+)\/submit$/);
  if (request.method === "POST" && packSubmitMatch?.[1]) {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return submitPackDraft(env, user, decodeURIComponent(packSubmitMatch[1]));
  }

  const packVersionMatch = url.pathname.match(/^\/api\/packs\/([^/]+)\/versions\/(\d+)$/);
  if (request.method === "GET" && packVersionMatch?.[1] && packVersionMatch?.[2]) {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return getPackVersion(env, decodeURIComponent(packVersionMatch[1]), Number(packVersionMatch[2]), user);
  }

  if (request.method === "GET" && url.pathname === "/api/admin/reviews") {
    await requireAdminUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return listReviewQueue(env);
  }

  const adminRuleReviewMatch = url.pathname.match(/^\/api\/admin\/rules\/([^/]+)\/versions\/(\d+)\/(approve|needs-changes)$/);
  if (request.method === "POST" && adminRuleReviewMatch?.[1] && adminRuleReviewMatch?.[2] && adminRuleReviewMatch?.[3]) {
    const admin = await requireAdminUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return reviewRule(
      request,
      env,
      admin,
      decodeURIComponent(adminRuleReviewMatch[1]),
      parseReviewVersion(adminRuleReviewMatch[2]),
      adminRuleReviewMatch[3] === "approve" ? "approved" : "needs_changes"
    );
  }

  const adminPackReviewMatch = url.pathname.match(/^\/api\/admin\/packs\/([^/]+)\/versions\/(\d+)\/(approve|needs-changes)$/);
  if (request.method === "POST" && adminPackReviewMatch?.[1] && adminPackReviewMatch?.[2] && adminPackReviewMatch?.[3]) {
    const admin = await requireAdminUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return reviewPack(
      request,
      env,
      admin,
      decodeURIComponent(adminPackReviewMatch[1]),
      parseReviewVersion(adminPackReviewMatch[2]),
      adminPackReviewMatch[3] === "approve" ? "approved" : "needs_changes"
    );
  }

  if (request.method === "GET" && url.pathname === "/api/spells/public") {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return listPublicSpells(env, url, user?.email ?? null);
  }

  if (request.method === "GET" && url.pathname === "/api/spells/mine") {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return listMySpells(env, user);
  }

  if (request.method === "POST" && url.pathname === "/api/spells") {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return upsertSpell(request, env, user);
  }

  const starMatch = url.pathname.match(/^\/api\/spells\/([^/]+)\/star$/);
  if ((request.method === "POST" || request.method === "DELETE") && starMatch?.[1]) {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return setSpellStar(env, decodeURIComponent(starMatch[1]), user, request.method === "POST");
  }

  const spellVersionMatch = url.pathname.match(/^\/api\/spells\/([^/]+)\/versions\/(\d+)$/);
  if (request.method === "GET" && spellVersionMatch?.[1] && spellVersionMatch?.[2]) {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return getPublicSpellVersion(
      env,
      decodeURIComponent(spellVersionMatch[1]),
      Number(spellVersionMatch[2]),
      user?.email ?? null
    );
  }

  const spellMatch = url.pathname.match(/^\/api\/spells\/([^/]+)$/);
  if (request.method === "GET" && spellMatch?.[1]) {
    const user = await authenticateOptionalUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return getPublicSpell(env, decodeURIComponent(spellMatch[1]), user?.email ?? null);
  }

  if (request.method === "DELETE" && spellMatch?.[1]) {
    const user = await authenticateUser(request, env.SPELLBOOK_JWT_SECRET, requireDatabase(env));
    return deleteSpell(env, decodeURIComponent(spellMatch[1]), user);
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
  const expiresAt = new Date(Date.now() + 1000 * 60 * 10).toISOString();
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

  const user = await ensureUser(db, email);
  const session = await signJwt(email, jwtSecret);
  return json({ token: session.token, email, role: user.role, expiresAt: session.expiresAt });
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

function classifyUnexpectedError(error: unknown): AppError {
  const message = error instanceof Error ? error.message : String(error);

  if (/no such table|no such column/i.test(message)) {
    return new AppError("Spellbook database schema and API deployment are out of sync. Apply the remote D1 migrations, then redeploy the Worker.", 503);
  }

  if (/SQLITE_ERROR|D1_ERROR|constraint failed|immutable/i.test(message)) {
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
