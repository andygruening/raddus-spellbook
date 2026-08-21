import { AppError, isRecord } from "./http";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const otpLength = 6;
const jwtTtlSeconds = 60 * 60 * 24 * 30;
const otpTtlMilliseconds = 1000 * 60 * 10;

export type JwtPayload = {
  email: string;
  exp: number;
  iat: number;
  iss: "raddus-spellbook";
};

export type AuthenticatedUser = {
  email: string;
};

export type UserRole = "user" | "admin";

export type DatabaseUser = {
  email: string;
  role: UserRole;
  created_at: string;
  updated_at: string;
};

export function normalizeEmail(email: unknown): string {
  if (typeof email !== "string") {
    throw new AppError("Enter a valid email address.", 400);
  }

  const normalized = email.trim().toLowerCase();
  const valid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized);

  if (!valid) {
    throw new AppError("Enter a valid email address.", 400);
  }

  return normalized;
}

export function otpExpiresAt(now = Date.now()): string {
  return new Date(now + otpTtlMilliseconds).toISOString();
}

export function jwtExpiresAt(now = Date.now()): string {
  return new Date(now + jwtTtlSeconds * 1000).toISOString();
}

export function generateOtpCode(): string {
  const modulo = 10 ** otpLength;
  const maxUnbiased = Math.floor(0xffffffff / modulo) * modulo;
  const bytes = new Uint8Array(4);

  while (true) {
    crypto.getRandomValues(bytes);
    const value = new DataView(bytes.buffer).getUint32(0);
    if (value < maxUnbiased) {
      return String(value % modulo).padStart(otpLength, "0");
    }
  }
}

export function randomToken(bytesLength = 32): string {
  const bytes = new Uint8Array(bytesLength);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

export async function hashOtp(email: string, code: string, salt: string, secret: string): Promise<string> {
  const digest = await sha256(`${email}:${code}:${salt}:${secret}`);
  return base64UrlEncode(new Uint8Array(digest));
}

export async function constantTimeEqual(left: string, right: string): Promise<boolean> {
  const [leftDigest, rightDigest] = await Promise.all([sha256(left), sha256(right)]);
  const leftBytes = new Uint8Array(leftDigest);
  const rightBytes = new Uint8Array(rightDigest);
  let diff = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);

  for (let index = 0; index < length; index += 1) {
    diff |= (leftBytes[index % leftBytes.length] ?? 0) ^ (rightBytes[index % rightBytes.length] ?? 0);
  }

  return diff === 0;
}

export async function signJwt(email: string, secret: string, now = Date.now()): Promise<{ token: string; expiresAt: string }> {
  requireSecret(secret, "Authentication is not configured.");

  const issuedAt = Math.floor(now / 1000);
  const expiresAtSeconds = issuedAt + jwtTtlSeconds;
  const header = base64UrlEncodeJson({ alg: "HS256", typ: "JWT" });
  const payload = base64UrlEncodeJson({
    email,
    exp: expiresAtSeconds,
    iat: issuedAt,
    iss: "raddus-spellbook"
  } satisfies JwtPayload);
  const signingInput = `${header}.${payload}`;
  const signature = await hmacSha256(signingInput, secret);

  return {
    token: `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`,
    expiresAt: new Date(expiresAtSeconds * 1000).toISOString()
  };
}

export async function verifyJwt(token: string, secret: string, now = Date.now()): Promise<AuthenticatedUser> {
  requireSecret(secret, "Authentication is not configured.");

  const parts = token.split(".");
  if (parts.length !== 3) {
    throw new AppError("Sign in again to continue.", 401);
  }

  const [header, payload, signature] = parts;
  if (!header || !payload || !signature) {
    throw new AppError("Sign in again to continue.", 401);
  }

  const expectedSignature = base64UrlEncode(new Uint8Array(await hmacSha256(`${header}.${payload}`, secret)));
  const validSignature = await constantTimeEqual(signature, expectedSignature);
  if (!validSignature) {
    throw new AppError("Sign in again to continue.", 401);
  }

  const decodedPayload = parseJwtPayload(payload);
  if (decodedPayload.iss !== "raddus-spellbook" || decodedPayload.exp * 1000 <= now) {
    throw new AppError("Your session expired. Sign in again.", 401);
  }

  return { email: normalizeEmail(decodedPayload.email) };
}

export async function authenticate(request: Request, secret: string | undefined): Promise<AuthenticatedUser> {
  const jwtSecret = requireSecret(secret, "Authentication is not configured.");
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    throw new AppError("Sign in to continue.", 401);
  }

  const token = authorization.slice("Bearer ".length).trim();
  if (!token) {
    throw new AppError("Sign in to continue.", 401);
  }

  return verifyJwt(token, jwtSecret);
}

export async function authenticateOptional(request: Request, secret: string | undefined): Promise<AuthenticatedUser | null> {
  const authorization = request.headers.get("Authorization");
  if (!authorization) {
    return null;
  }

  return authenticate(request, secret);
}

export async function ensureUser(db: D1Database, email: string): Promise<DatabaseUser> {
  const normalized = normalizeEmail(email);
  const now = new Date().toISOString();

  await db.prepare(
    `INSERT INTO users (email, role, created_at, updated_at)
     VALUES (?, 'user', ?, ?)
     ON CONFLICT(email) DO UPDATE SET updated_at = excluded.updated_at`
  )
    .bind(normalized, now, now)
    .run();

  const user = await db.prepare(
    `SELECT email, role, created_at, updated_at
     FROM users
     WHERE email = ?
     LIMIT 1`
  )
    .bind(normalized)
    .first<DatabaseUser>();

  if (!user || !isUserRole(user.role)) {
    throw new AppError("Sign in again to continue.", 401);
  }

  return user;
}

export async function authenticateUser(
  request: Request,
  secret: string | undefined,
  db: D1Database
): Promise<DatabaseUser> {
  const session = await authenticate(request, secret);
  return ensureUser(db, session.email);
}

export async function authenticateOptionalUser(
  request: Request,
  secret: string | undefined,
  db: D1Database
): Promise<DatabaseUser | null> {
  const session = await authenticateOptional(request, secret);
  if (!session) {
    return null;
  }

  return ensureUser(db, session.email);
}

export async function requireAdminUser(
  request: Request,
  secret: string | undefined,
  db: D1Database
): Promise<DatabaseUser> {
  const user = await authenticateUser(request, secret, db);
  if (user.role !== "admin") {
    throw new AppError("Admin access is required.", 403);
  }

  return user;
}

export function requireSecret(value: string | undefined, message: string): string {
  if (!value || value.trim().length === 0) {
    throw new AppError(message, 503);
  }

  return value;
}

function parseJwtPayload(encodedPayload: string): JwtPayload {
  let parsed: unknown;

  try {
    parsed = JSON.parse(decoder.decode(base64UrlDecode(encodedPayload)));
  } catch {
    throw new AppError("Sign in again to continue.", 401);
  }

  if (isJwtPayload(parsed)) {
    return parsed;
  }

  throw new AppError("Sign in again to continue.", 401);
}

function isJwtPayload(value: unknown): value is JwtPayload {
  return (
    isRecord(value) &&
    typeof value.email === "string" &&
    typeof value.exp === "number" &&
    typeof value.iat === "number" &&
    value.iss === "raddus-spellbook"
  );
}

function isUserRole(value: unknown): value is UserRole {
  return value === "user" || value === "admin";
}

async function hmacSha256(message: string, secret: string): Promise<ArrayBuffer> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  return crypto.subtle.sign("HMAC", key, encoder.encode(message));
}

async function sha256(value: string): Promise<ArrayBuffer> {
  return crypto.subtle.digest("SHA-256", encoder.encode(value));
}

function base64UrlEncodeJson(value: Record<string, unknown>): string {
  return base64UrlEncode(encoder.encode(JSON.stringify(value)));
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function base64UrlDecode(value: string): Uint8Array {
  const padded = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);

  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }

  return bytes;
}
