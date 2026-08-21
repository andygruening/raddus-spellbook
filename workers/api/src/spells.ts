import { AppError, isRecord } from "./http";
import type { DatabaseUser } from "./auth";
import { nowIso, parseLimit, requireDatabase, type SpellbookEnv } from "./db";
import {
  findLatestApprovedRule,
  findLatestRule,
  findRuleVersion,
  listMyRuleRows,
  listPublicRuleRows,
  type RuleRow
} from "./rules";
import { json, readJsonObject } from "./http";

export type SpellInput = {
  uid: string | null;
  name: string;
  description: string;
  trigger: string;
  file: string;
  content: string;
};

export type SpellRow = {
  id: string;
  name: string;
  description: string;
  trigger: string;
  file: string;
  content: string;
  version: number;
  owner_email: string;
  published: number;
  created_at: string;
  updated_at: string;
  published_at: string;
  star_count: number;
  starred_by_viewer: number;
};

export type SpellResponse = {
  uid: string;
  name: string;
  description: string;
  trigger: string;
  file: string;
  content: string;
  version: number;
  ownerEmail: string;
  publishedAt: string | null;
  starCount: number;
  starredByMe: boolean;
};

export function parseSpellInput(body: Record<string, unknown>): SpellInput {
  const name = requiredText(body.name, "Name is required.", 120);
  if (body.file !== undefined && body.file !== null && typeof body.file !== "string") {
    throw new AppError("Instruction files must live under ./instructions and end in .md.", 400);
  }

  const file = optionalText(body.file, 240) ?? `instructions/${slugForFile(name)}.md`;

  return {
    uid: optionalText(body.uid, 160),
    name,
    description: requiredText(body.description, "Description is required.", 500),
    trigger: requiredText(body.trigger, "Trigger is required.", 1000),
    file: validatedFile(file),
    content: requiredText(body.content, "Markdown content is required.", 50000)
  };
}

export function rowToSpell(row: SpellRow): SpellResponse {
  return {
    uid: row.id,
    name: row.name,
    description: row.description,
    trigger: row.trigger,
    file: row.file,
    content: row.content,
    version: row.version,
    ownerEmail: row.owner_email,
    publishedAt: row.published_at || null,
    starCount: row.star_count,
    starredByMe: row.starred_by_viewer === 1
  };
}

export function rowsToSpells(rows: SpellRow[]): SpellResponse[] {
  return rows.map(rowToSpell);
}

function requiredText(value: unknown, message: string, maxLength: number): string {
  const text = optionalText(value, maxLength);
  if (!text) {
    throw new AppError(message, 400);
  }

  return text;
}

function optionalText(value: unknown, maxLength: number): string | null {
  if (value === undefined || value === null) {
    return null;
  }

  if (typeof value !== "string") {
    return null;
  }

  const text = value.trim();
  if (text.length === 0) {
    return null;
  }

  if (text.length > maxLength) {
    throw new AppError("One of the spell fields is too long.", 400);
  }

  return text;
}

function validatedFile(value: string): string {
  if (value.startsWith("/") || value.includes("..")) {
    throw new AppError("Instruction files must live under ./instructions and end in .md.", 400);
  }

  const parts = value.split("/");
  const [directory, fileName] = parts;
  if (
    parts.length !== 2 ||
    directory !== "instructions" ||
    !fileName ||
    !fileName.endsWith(".md") ||
    fileName.length <= 3
  ) {
    throw new AppError("Instruction files must live under ./instructions and end in .md.", 400);
  }

  return value;
}

function slugForFile(value: string): string {
  const slug = value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return slug || "spell";
}

export function isSpellResponse(value: unknown): value is SpellResponse {
  return (
    isRecord(value) &&
    typeof value.uid === "string" &&
    typeof value.name === "string" &&
    typeof value.description === "string" &&
    typeof value.trigger === "string" &&
    typeof value.file === "string" &&
    typeof value.content === "string" &&
    typeof value.version === "number"
  );
}

export async function listPublicSpells(env: SpellbookEnv, url: URL, viewerEmail: string | null): Promise<Response> {
  const rows = await listPublicRuleRows(requireDatabase(env), parseLimit(url.searchParams.get("limit")), viewerEmail);
  return json({ spells: rows.map(ruleRowToSpell) });
}

export async function listMySpells(env: SpellbookEnv, user: DatabaseUser): Promise<Response> {
  const rows = await listMyRuleRows(requireDatabase(env), user.email);
  return json({ spells: rows.map(ruleRowToSpell) });
}

export async function upsertSpell(request: Request, env: SpellbookEnv, user: DatabaseUser): Promise<Response> {
  const db = requireDatabase(env);
  const input = parseSpellInput(await readJsonObject(request));
  const now = nowIso();

  if (input.uid) {
    const latest = await findLatestRule(db, input.uid, user.email);
    if (!latest) {
      throw new AppError("Spell not found.", 404);
    }

    if (latest.owner_email !== user.email) {
      throw new AppError("Only the creator can update this spell.", 403);
    }

    if (latest.state === "approved") {
      const nextVersion = latest.version + 1;
      await db.batch([
        db.prepare("UPDATE rules SET updated_at = ? WHERE uid = ?").bind(now, input.uid),
        db.prepare(
          `INSERT INTO rule_versions (
             rule_uid, version, state, name, description, applies_when, file, body,
             created_at, updated_at
           )
           VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?)`
        )
          .bind(
            input.uid,
            nextVersion,
            input.name,
            input.description,
            input.trigger,
            input.file,
            input.content,
            now,
            now
          )
      ]);

      const created = await findRuleVersion(db, input.uid, nextVersion, user.email);
      if (!created) {
        throw new AppError("Spell not found.", 404);
      }

      return json({ spell: ruleRowToSpell(created) }, { status: 201 });
    }

    if (latest.state !== "draft" && latest.state !== "submitted_for_review" && latest.state !== "needs_changes") {
      throw new AppError("This spell cannot be edited.", 409);
    }

    await db.batch([
      db.prepare("UPDATE rules SET updated_at = ? WHERE uid = ?").bind(now, input.uid),
      db.prepare(
        `UPDATE rule_versions
         SET name = ?, description = ?, applies_when = ?, file = ?, body = ?, updated_at = ?
         WHERE rule_uid = ? AND version = ?`
      )
        .bind(input.name, input.description, input.trigger, input.file, input.content, now, input.uid, latest.version)
    ]);

    const updated = await findRuleVersion(db, input.uid, latest.version, user.email);
    if (!updated) {
      throw new AppError("Spell not found.", 404);
    }

    return json({ spell: ruleRowToSpell(updated) });
  }

  const uid = crypto.randomUUID();
  await db.batch([
    db.prepare(
      `INSERT INTO rules (uid, owner_email, created_at, updated_at)
       VALUES (?, ?, ?, ?)`
    )
      .bind(uid, user.email, now, now),
    db.prepare(
      `INSERT INTO rule_versions (
         rule_uid, version, state, name, description, applies_when, file, body,
         created_at, updated_at
       )
       VALUES (?, 1, 'draft', ?, ?, ?, ?, ?, ?, ?)`
    )
      .bind(uid, input.name, input.description, input.trigger, input.file, input.content, now, now)
  ]);

  const created = await findRuleVersion(db, uid, 1, user.email);
  if (!created) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: ruleRowToSpell(created) }, { status: 201 });
}

export async function getPublicSpell(env: SpellbookEnv, uid: string, viewerEmail: string | null): Promise<Response> {
  const rule = await findLatestApprovedRule(requireDatabase(env), uid, viewerEmail);
  if (!rule) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: ruleRowToSpell(rule) });
}

export async function getPublicSpellVersion(
  env: SpellbookEnv,
  uid: string,
  version: number,
  viewerEmail: string | null
): Promise<Response> {
  const rule = await findRuleVersion(requireDatabase(env), uid, version, viewerEmail);
  if (!rule || (rule.state !== "approved" && rule.owner_email !== viewerEmail)) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: ruleRowToSpell(rule) });
}

export async function deleteSpell(env: SpellbookEnv, uid: string, user: DatabaseUser): Promise<Response> {
  const db = requireDatabase(env);
  const latest = await findLatestRule(db, uid, user.email);
  if (!latest) {
    throw new AppError("Spell not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can delete this spell", 403);
  }

  await db.prepare("UPDATE rules SET archived_at = ?, updated_at = ? WHERE uid = ?")
    .bind(nowIso(), nowIso(), uid)
    .run();
  return json({ ok: true });
}

export async function setSpellStar(env: SpellbookEnv, uid: string, user: DatabaseUser, starred: boolean): Promise<Response> {
  const db = requireDatabase(env);
  const approved = await findLatestApprovedRule(db, uid, user.email);
  if (!approved) {
    throw new AppError("Spell not found.", 404);
  }

  if (starred) {
    await db.prepare(
      `INSERT OR IGNORE INTO rule_stars (rule_uid, owner_email, created_at)
       VALUES (?, ?, ?)`
    )
      .bind(uid, user.email, nowIso())
      .run();
  } else {
    await db.prepare("DELETE FROM rule_stars WHERE rule_uid = ? AND owner_email = ?")
      .bind(uid, user.email)
      .run();
  }

  const updated = await findLatestApprovedRule(db, uid, user.email);
  if (!updated) {
    throw new AppError("Spell not found.", 404);
  }

  return json({ spell: ruleRowToSpell(updated) });
}

export function ruleRowToSpell(row: RuleRow): SpellResponse {
  return {
    uid: row.uid,
    name: row.name,
    description: row.description,
    trigger: row.applies_when,
    file: row.file,
    content: row.body,
    version: row.version,
    ownerEmail: row.owner_email,
    publishedAt: row.approved_at,
    starCount: row.star_count,
    starredByMe: row.starred_by_viewer === 1
  };
}
