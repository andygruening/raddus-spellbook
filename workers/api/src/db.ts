import { AppError } from "./http";

export type SpellbookSecrets = {
  SPELLBOOK_JWT_SECRET?: string;
  RESEND_API_KEY?: string;
  RESEND_FROM_EMAIL?: string;
};

export type SpellbookConfig = {
  SPELLBOOK_WEB_URL?: string;
  SPELLBOOK_MACOS_DEEPLINK_SCHEME?: string;
};

export type SpellbookEnv = Env & SpellbookSecrets & SpellbookConfig;

export function requireDatabase(env: SpellbookEnv): D1Database {
  if (!env.DB) {
    throw new AppError("Spellbook database is not configured. Add the D1 DB binding and redeploy the Worker.", 503);
  }

  return env.DB;
}

export function parseLimit(value: string | null): number {
  if (!value) {
    return 100;
  }

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    return 100;
  }

  return Math.min(parsed, 100);
}

export function nowIso(): string {
  return new Date().toISOString();
}
