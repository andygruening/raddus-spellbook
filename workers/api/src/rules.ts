import type { DatabaseUser } from "./auth";
import { nowIso, parseLimit, requireDatabase, type SpellbookEnv } from "./db";
import { AppError, isRecord, json, readJsonObject } from "./http";

export type LifecycleState =
  | "draft"
  | "submitted_for_review"
  | "needs_changes"
  | "approved"
  | "withdrawn"
  | "archived";

export type RuleInput = {
  name: string;
  description: string;
  appliesWhen: string;
  file: string;
  body: string;
};

export type RulePatch = Partial<RuleInput>;

export type RuleRow = {
  uid: string;
  owner_email: string;
  version: number;
  state: LifecycleState;
  name: string;
  description: string;
  applies_when: string;
  file: string;
  body: string;
  created_at: string;
  updated_at: string;
  submitted_at: string | null;
  approved_at: string | null;
  reviewed_at: string | null;
  reviewer_email: string | null;
  review_notes: string | null;
  star_count: number;
  starred_by_viewer: number;
};

export type RuleResponse = {
  uid: string;
  version: number;
  lifecycleState: LifecycleState;
  name: string;
  description: string;
  appliesWhen: string;
  file: string;
  body: string;
  ownerEmail: string;
  createdAt: string;
  updatedAt: string;
  submittedAt: string | null;
  approvedAt: string | null;
  reviewedAt: string | null;
  reviewerEmail: string | null;
  reviewNotes: string | null;
  starCount: number;
  starredByMe: boolean;
};

export async function createRule(request: Request, env: SpellbookEnv, user: DatabaseUser): Promise<Response> {
  const db = requireDatabase(env);
  const input = parseRuleInput(await readJsonObject(request));
  const uid = crypto.randomUUID();
  const now = nowIso();

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
      .bind(uid, input.name, input.description, input.appliesWhen, input.file, input.body, now, now)
  ]);

  const created = await findRuleVersion(db, uid, 1, user.email);
  if (!created) {
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(created) }, { status: 201 });
}

export async function updateRuleDraft(request: Request, env: SpellbookEnv, user: DatabaseUser, uid: string): Promise<Response> {
  const db = requireDatabase(env);
  const patch = parseRulePatch(await readJsonObject(request));
  const latest = await findLatestRule(db, uid, user.email);

  if (!latest) {
    throw new AppError("Rule not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can update this rule.", 403);
  }

  const now = nowIso();
  if (latest.state === "approved") {
    const nextVersion = latest.version + 1;
    const next = mergeRuleInput(latest, patch);
    await db.batch([
      db.prepare("UPDATE rules SET updated_at = ? WHERE uid = ?").bind(now, uid),
      db.prepare(
        `INSERT INTO rule_versions (
           rule_uid, version, state, name, description, applies_when, file, body,
           created_at, updated_at
         )
         VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?)`
      )
        .bind(uid, nextVersion, next.name, next.description, next.appliesWhen, next.file, next.body, now, now)
    ]);

    const created = await findRuleVersion(db, uid, nextVersion, user.email);
    if (!created) {
      throw new AppError("Rule not found.", 404);
    }

    return json({ rule: rowToRule(created) }, { status: 201 });
  }

  if (!isMutableRuleState(latest.state)) {
    throw new AppError("This rule version cannot be edited.", 409);
  }

  const next = mergeRuleInput(latest, patch);
  await db.batch([
    db.prepare("UPDATE rules SET updated_at = ? WHERE uid = ?").bind(now, uid),
    db.prepare(
      `UPDATE rule_versions
       SET name = ?, description = ?, applies_when = ?, file = ?, body = ?, updated_at = ?
       WHERE rule_uid = ? AND version = ?`
    )
      .bind(next.name, next.description, next.appliesWhen, next.file, next.body, now, uid, latest.version)
  ]);

  const updated = await findRuleVersion(db, uid, latest.version, user.email);
  if (!updated) {
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(updated) });
}

export async function submitRuleDraft(env: SpellbookEnv, user: DatabaseUser, uid: string): Promise<Response> {
  const db = requireDatabase(env);
  const latest = await findLatestRule(db, uid, user.email);

  if (!latest) {
    throw new AppError("Rule not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can submit this rule.", 403);
  }

  if (!isMutableRuleState(latest.state)) {
    throw new AppError("This rule version cannot be submitted.", 409);
  }

  const now = nowIso();
  await db.batch([
    db.prepare(
      `UPDATE rule_versions
       SET state = 'submitted_for_review', submitted_at = ?, updated_at = ?, review_notes = NULL
       WHERE rule_uid = ? AND version = ?`
    )
      .bind(now, now, uid, latest.version),
    db.prepare(
      `INSERT INTO review_events (id, artifact_type, artifact_uid, artifact_version, action, actor_email, notes, created_at)
       VALUES (?, 'rule', ?, ?, 'submitted', ?, NULL, ?)`
    )
      .bind(crypto.randomUUID(), uid, latest.version, user.email, now)
  ]);

  const submitted = await findRuleVersion(db, uid, latest.version, user.email);
  if (!submitted) {
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(submitted) });
}

export async function listPublicRules(env: SpellbookEnv, url: URL, viewerEmail: string | null): Promise<Response> {
  const db = requireDatabase(env);
  const rows = await listPublicRuleRows(db, parseLimit(url.searchParams.get("limit")), viewerEmail);
  return json({ rules: rows.map(rowToRule) });
}

export async function listPublicRuleRows(
  db: D1Database,
  limit: number,
  viewerEmail: string | null
): Promise<RuleRow[]> {
  const result = await db.prepare(
    `${ruleSelectSql()}
     WHERE rules.archived_at IS NULL
       AND rule_versions.state = 'approved'
       AND rule_versions.version = (
         SELECT MAX(version)
         FROM rule_versions latest
         WHERE latest.rule_uid = rule_versions.rule_uid
           AND latest.state = 'approved'
       )
     ORDER BY rule_versions.approved_at DESC, rule_versions.updated_at DESC
     LIMIT ?`
  )
    .bind(viewerEmail, viewerEmail, limit)
    .all<RuleRow>();

  return result.results;
}

export async function listMyRules(env: SpellbookEnv, user: DatabaseUser): Promise<Response> {
  const db = requireDatabase(env);
  const rows = await listMyRuleRows(db, user.email);
  return json({ rules: rows.map(rowToRule) });
}

export async function listMyRuleRows(db: D1Database, ownerEmail: string): Promise<RuleRow[]> {
  const result = await db.prepare(
    `${ruleSelectSql()}
     WHERE rules.owner_email = ?
       AND rules.archived_at IS NULL
       AND rule_versions.version = (
         SELECT MAX(version)
         FROM rule_versions latest
         WHERE latest.rule_uid = rule_versions.rule_uid
       )
     ORDER BY rule_versions.updated_at DESC`
  )
    .bind(ownerEmail, ownerEmail, ownerEmail)
    .all<RuleRow>();

  return result.results;
}

export async function getRuleDraft(env: SpellbookEnv, user: DatabaseUser, uid: string): Promise<Response> {
  const db = requireDatabase(env);
  const latest = await findLatestRule(db, uid, user.email);

  if (!latest) {
    throw new AppError("Rule not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can read this rule draft.", 403);
  }

  return json({ rule: rowToRule(latest) });
}

export async function getRuleVersion(
  env: SpellbookEnv,
  uid: string,
  version: number,
  viewerEmail: string | null
): Promise<Response> {
  if (!Number.isInteger(version) || version < 1) {
    throw new AppError("Rule not found.", 404);
  }

  const db = requireDatabase(env);
  const rule = await findRuleVersion(db, uid, version, viewerEmail);
  if (!rule || (rule.state !== "approved" && rule.owner_email !== viewerEmail)) {
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(rule) });
}

export async function getLatestPublicRule(env: SpellbookEnv, uid: string, viewerEmail: string | null): Promise<Response> {
  const db = requireDatabase(env);
  const rule = await findLatestApprovedRule(db, uid, viewerEmail);
  if (!rule) {
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(rule) });
}

export async function setRuleStar(
  env: SpellbookEnv,
  uid: string,
  user: DatabaseUser,
  starred: boolean
): Promise<Response> {
  const db = requireDatabase(env);
  const approved = await findLatestApprovedRule(db, uid, user.email);
  if (!approved) {
    throw new AppError("Rule not found.", 404);
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
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(updated) });
}

export async function reviewRuleVersion(
  env: SpellbookEnv,
  admin: DatabaseUser,
  uid: string,
  version: number,
  action: "approved" | "needs_changes",
  notes: string | null
): Promise<Response> {
  const db = requireDatabase(env);
  const rule = await findRuleVersion(db, uid, version, admin.email);

  if (!rule) {
    throw new AppError("Rule not found.", 404);
  }

  if (rule.state !== "submitted_for_review") {
    throw new AppError("Only submitted rules can be reviewed.", 409);
  }

  const now = nowIso();
  const update = action === "approved"
    ? db.prepare(
      `UPDATE rule_versions
       SET state = 'approved', approved_at = ?, reviewed_at = ?, reviewer_email = ?, review_notes = ?, updated_at = ?
       WHERE rule_uid = ? AND version = ?`
    )
      .bind(now, now, admin.email, notes, now, uid, version)
    : db.prepare(
      `UPDATE rule_versions
       SET state = 'needs_changes', reviewed_at = ?, reviewer_email = ?, review_notes = ?, updated_at = ?
       WHERE rule_uid = ? AND version = ?`
    )
      .bind(now, admin.email, requireNotes(notes), now, uid, version);

  await db.batch([
    update,
    db.prepare(
      `INSERT INTO review_events (id, artifact_type, artifact_uid, artifact_version, action, actor_email, notes, created_at)
       VALUES (?, 'rule', ?, ?, ?, ?, ?, ?)`
    )
      .bind(crypto.randomUUID(), uid, version, action, admin.email, notes, now)
  ]);

  const reviewed = await findRuleVersion(db, uid, version, admin.email);
  if (!reviewed) {
    throw new AppError("Rule not found.", 404);
  }

  return json({ rule: rowToRule(reviewed) });
}

export async function findRuleVersion(
  db: D1Database,
  uid: string,
  version: number,
  viewerEmail: string | null = null
): Promise<RuleRow | null> {
  return db.prepare(
    `${ruleSelectSql()}
     WHERE rules.uid = ? AND rule_versions.version = ?
     LIMIT 1`
  )
    .bind(viewerEmail, viewerEmail, uid, version)
    .first<RuleRow>();
}

export async function findLatestRule(
  db: D1Database,
  uid: string,
  viewerEmail: string | null = null
): Promise<RuleRow | null> {
  return db.prepare(
    `${ruleSelectSql()}
     WHERE rules.uid = ?
     ORDER BY rule_versions.version DESC
     LIMIT 1`
  )
    .bind(viewerEmail, viewerEmail, uid)
    .first<RuleRow>();
}

export async function findLatestApprovedRule(
  db: D1Database,
  uid: string,
  viewerEmail: string | null = null
): Promise<RuleRow | null> {
  return db.prepare(
    `${ruleSelectSql()}
     WHERE rules.uid = ?
       AND rules.archived_at IS NULL
       AND rule_versions.state = 'approved'
     ORDER BY rule_versions.version DESC
     LIMIT 1`
  )
    .bind(viewerEmail, viewerEmail, uid)
    .first<RuleRow>();
}

export function rowToRule(row: RuleRow): RuleResponse {
  return {
    uid: row.uid,
    version: row.version,
    lifecycleState: row.state,
    name: row.name,
    description: row.description,
    appliesWhen: row.applies_when,
    file: row.file,
    body: row.body,
    ownerEmail: row.owner_email,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    submittedAt: row.submitted_at,
    approvedAt: row.approved_at,
    reviewedAt: row.reviewed_at,
    reviewerEmail: row.reviewer_email,
    reviewNotes: row.review_notes,
    starCount: row.star_count,
    starredByMe: row.starred_by_viewer === 1
  };
}

export function parseRuleInput(body: Record<string, unknown>): RuleInput {
  const name = requiredText(body.name, "Name is required.", 120);
  return {
    name,
    description: requiredText(body.description, "Description is required.", 500),
    appliesWhen: requiredText(body.appliesWhen ?? body.trigger, "Applies when is required.", 1000),
    file: optionalText(body.file, 240) ?? "SPEC.md",
    body: requiredText(body.body ?? body.content, "Rule body is required.", 50000)
  };
}

export function parseRulePatch(body: Record<string, unknown>): RulePatch {
  const patch: RulePatch = {};

  if (body.name !== undefined) {
    patch.name = requiredText(body.name, "Name is required.", 120);
  }
  if (body.description !== undefined) {
    patch.description = requiredText(body.description, "Description is required.", 500);
  }
  if (body.appliesWhen !== undefined || body.trigger !== undefined) {
    patch.appliesWhen = requiredText(body.appliesWhen ?? body.trigger, "Applies when is required.", 1000);
  }
  if (body.file !== undefined) {
    patch.file = requiredText(body.file, "File is required.", 240);
  }
  if (body.body !== undefined || body.content !== undefined) {
    patch.body = requiredText(body.body ?? body.content, "Rule body is required.", 50000);
  }

  if (Object.keys(patch).length === 0) {
    throw new AppError("Send at least one rule field to update.", 400);
  }

  return patch;
}

export function isMutableRuleState(state: LifecycleState): boolean {
  return state === "draft" || state === "submitted_for_review" || state === "needs_changes";
}

function ruleSelectSql(): string {
  return `SELECT
            rules.uid,
            rules.owner_email,
            rule_versions.version,
            rule_versions.state,
            rule_versions.name,
            rule_versions.description,
            rule_versions.applies_when,
            rule_versions.file,
            rule_versions.body,
            rule_versions.created_at,
            rule_versions.updated_at,
            rule_versions.submitted_at,
            rule_versions.approved_at,
            rule_versions.reviewed_at,
            rule_versions.reviewer_email,
            rule_versions.review_notes,
            (SELECT COUNT(*) FROM rule_stars WHERE rule_stars.rule_uid = rules.uid) AS star_count,
            CASE
              WHEN ? IS NOT NULL AND EXISTS (
                SELECT 1 FROM rule_stars
                WHERE rule_stars.rule_uid = rules.uid AND rule_stars.owner_email = ?
              )
              THEN 1
              ELSE 0
            END AS starred_by_viewer
          FROM rules
          JOIN rule_versions ON rule_versions.rule_uid = rules.uid`;
}

function mergeRuleInput(row: RuleRow, patch: RulePatch): RuleInput {
  return {
    name: patch.name ?? row.name,
    description: patch.description ?? row.description,
    appliesWhen: patch.appliesWhen ?? row.applies_when,
    file: patch.file ?? row.file,
    body: patch.body ?? row.body
  };
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
    throw new AppError("One of the rule fields has the wrong type.", 400);
  }

  const text = value.trim();
  if (text.length === 0) {
    return null;
  }

  if (text.length > maxLength) {
    throw new AppError("One of the rule fields is too long.", 400);
  }

  return text;
}

function requireNotes(notes: string | null): string {
  const parsed = optionalText(notes, 5000);
  if (!parsed) {
    throw new AppError("Review notes are required when requesting changes.", 400);
  }

  return parsed;
}

export function parseReviewNotes(body: Record<string, unknown>): string | null {
  if (body.notes === undefined || body.notes === null) {
    return null;
  }

  if (!isRecord(body) || typeof body.notes !== "string") {
    throw new AppError("Review notes must be text.", 400);
  }

  return optionalText(body.notes, 5000);
}
