import type { DatabaseUser } from "./auth";
import { nowIso, parseLimit, requireDatabase, type SpellbookEnv } from "./db";
import { AppError, json, readJsonObject } from "./http";
import { findRuleVersion, isMutableRuleState, type LifecycleState } from "./rules";

type PackRuleRef = {
  uid: string;
  version: number;
};

type ValidatedPackRuleRef = PackRuleRef & {
  includedDraftRule: boolean;
};

type PackInput = {
  name: string;
  description: string;
  audience: string;
  suggestedWorkspaceType: string;
  compatibility: Record<string, unknown>;
  releaseNotes: string;
  rules: PackRuleRef[];
};

type PackPatch = Partial<Omit<PackInput, "rules">> & {
  rules?: PackRuleRef[];
};

type PackRow = {
  uid: string;
  owner_email: string;
  version: number;
  state: LifecycleState;
  name: string;
  description: string;
  audience: string;
  suggested_workspace_type: string;
  compatibility_json: string;
  release_notes: string;
  created_at: string;
  updated_at: string;
  submitted_at: string | null;
  approved_at: string | null;
  reviewed_at: string | null;
  reviewer_email: string | null;
  review_notes: string | null;
};

type PackRuleRow = {
  rule_uid: string;
  rule_version: number;
  included_draft_rule: number;
  position: number;
  state: LifecycleState;
  name: string;
  owner_email: string;
};

export type PackResponse = {
  uid: string;
  version: number;
  lifecycleState: LifecycleState;
  name: string;
  description: string;
  audience: string;
  suggestedWorkspaceType: string;
  compatibility: Record<string, unknown>;
  releaseNotes: string;
  ownerEmail: string;
  createdAt: string;
  updatedAt: string;
  submittedAt: string | null;
  approvedAt: string | null;
  reviewedAt: string | null;
  reviewerEmail: string | null;
  reviewNotes: string | null;
  rules: Array<{
    uid: string;
    version: number;
    lifecycleState: LifecycleState;
    name: string;
    ownerEmail: string;
    includedDraftRule: boolean;
  }>;
};

export async function createPack(request: Request, env: SpellbookEnv, user: DatabaseUser): Promise<Response> {
  const db = requireDatabase(env);
  const input = parsePackInput(await readJsonObject(request));
  const refs = await validatePackRuleRefs(db, input.rules, user.email);
  const uid = crypto.randomUUID();
  const now = nowIso();

  await db.batch([
    db.prepare(
      `INSERT INTO packs (uid, owner_email, created_at, updated_at)
       VALUES (?, ?, ?, ?)`
    )
      .bind(uid, user.email, now, now),
    db.prepare(
      `INSERT INTO pack_versions (
         pack_uid, version, state, name, description, audience, suggested_workspace_type,
         compatibility_json, release_notes, created_at, updated_at
       )
       VALUES (?, 1, 'draft', ?, ?, ?, ?, ?, ?, ?, ?)`
    )
      .bind(
        uid,
        input.name,
        input.description,
        input.audience,
        input.suggestedWorkspaceType,
        JSON.stringify(input.compatibility),
        input.releaseNotes,
        now,
        now
      ),
    ...packRuleStatements(db, uid, 1, refs)
  ]);

  return json({ pack: await getPackResponse(db, uid, 1) }, { status: 201 });
}

export async function updatePackDraft(request: Request, env: SpellbookEnv, user: DatabaseUser, uid: string): Promise<Response> {
  const db = requireDatabase(env);
  const patch = parsePackPatch(await readJsonObject(request));
  const latest = await findLatestPack(db, uid);

  if (!latest) {
    throw new AppError("Pack not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can update this pack.", 403);
  }

  const now = nowIso();
  const next = mergePackInput(latest, patch);
  const refs = patch.rules ? await validatePackRuleRefs(db, patch.rules, user.email) : await getExistingPackRuleRefs(db, uid, latest.version);

  if (latest.state === "approved") {
    const nextVersion = latest.version + 1;
    await db.batch([
      db.prepare("UPDATE packs SET updated_at = ? WHERE uid = ?").bind(now, uid),
      db.prepare(
        `INSERT INTO pack_versions (
           pack_uid, version, state, name, description, audience, suggested_workspace_type,
           compatibility_json, release_notes, created_at, updated_at
         )
         VALUES (?, ?, 'draft', ?, ?, ?, ?, ?, ?, ?, ?)`
      )
        .bind(
          uid,
          nextVersion,
          next.name,
          next.description,
          next.audience,
          next.suggestedWorkspaceType,
          JSON.stringify(next.compatibility),
          next.releaseNotes,
          now,
          now
        ),
      ...packRuleStatements(db, uid, nextVersion, refs)
    ]);

    return json({ pack: await getPackResponse(db, uid, nextVersion) }, { status: 201 });
  }

  if (!isMutableRuleState(latest.state)) {
    throw new AppError("This pack version cannot be edited.", 409);
  }

  await db.batch([
    db.prepare("UPDATE packs SET updated_at = ? WHERE uid = ?").bind(now, uid),
    db.prepare(
      `UPDATE pack_versions
       SET name = ?, description = ?, audience = ?, suggested_workspace_type = ?,
           compatibility_json = ?, release_notes = ?, updated_at = ?
       WHERE pack_uid = ? AND version = ?`
    )
      .bind(
        next.name,
        next.description,
        next.audience,
        next.suggestedWorkspaceType,
        JSON.stringify(next.compatibility),
        next.releaseNotes,
        now,
        uid,
        latest.version
      ),
    db.prepare("DELETE FROM pack_version_rules WHERE pack_uid = ? AND pack_version = ?").bind(uid, latest.version),
    ...packRuleStatements(db, uid, latest.version, refs)
  ]);

  return json({ pack: await getPackResponse(db, uid, latest.version) });
}

export async function submitPackDraft(env: SpellbookEnv, user: DatabaseUser, uid: string): Promise<Response> {
  const db = requireDatabase(env);
  const latest = await findLatestPack(db, uid);

  if (!latest) {
    throw new AppError("Pack not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can submit this pack.", 403);
  }

  if (!isMutableRuleState(latest.state)) {
    throw new AppError("This pack version cannot be submitted.", 409);
  }

  const refs = await getPackRules(db, uid, latest.version);
  if (refs.length === 0) {
    throw new AppError("Add at least one rule before submitting this pack.", 400);
  }

  const now = nowIso();
  const draftRuleUpdates = refs
    .filter((ref) => ref.included_draft_rule === 1)
    .map((ref) =>
      db.prepare(
        `UPDATE rule_versions
         SET state = 'submitted_for_review', submitted_at = ?, updated_at = ?, review_notes = NULL
         WHERE rule_uid = ? AND version = ? AND state IN ('draft', 'submitted_for_review', 'needs_changes')`
      )
        .bind(now, now, ref.rule_uid, ref.rule_version)
    );

  await db.batch([
    db.prepare(
      `UPDATE pack_versions
       SET state = 'submitted_for_review', submitted_at = ?, updated_at = ?, review_notes = NULL
       WHERE pack_uid = ? AND version = ?`
    )
      .bind(now, now, uid, latest.version),
    ...draftRuleUpdates,
    db.prepare(
      `INSERT INTO review_events (id, artifact_type, artifact_uid, artifact_version, action, actor_email, notes, created_at)
       VALUES (?, 'pack', ?, ?, 'submitted', ?, NULL, ?)`
    )
      .bind(crypto.randomUUID(), uid, latest.version, user.email, now)
  ]);

  return json({ pack: await getPackResponse(db, uid, latest.version) });
}

export async function listPublicPacks(env: SpellbookEnv, url: URL): Promise<Response> {
  const db = requireDatabase(env);
  const result = await db.prepare(
    `${packSelectSql()}
     WHERE packs.archived_at IS NULL
       AND pack_versions.state = 'approved'
       AND pack_versions.version = (
         SELECT MAX(version)
         FROM pack_versions latest
         WHERE latest.pack_uid = pack_versions.pack_uid
           AND latest.state = 'approved'
       )
     ORDER BY pack_versions.approved_at DESC, pack_versions.updated_at DESC
     LIMIT ?`
  )
    .bind(parseLimit(url.searchParams.get("limit")))
    .all<PackRow>();

  const packs = [];
  for (const row of result.results) {
    packs.push(await rowToPack(db, row));
  }

  return json({ packs });
}

export async function listMyPacks(env: SpellbookEnv, user: DatabaseUser): Promise<Response> {
  const db = requireDatabase(env);
  const result = await db.prepare(
    `${packSelectSql()}
     WHERE packs.owner_email = ?
       AND packs.archived_at IS NULL
       AND pack_versions.version = (
         SELECT MAX(version)
         FROM pack_versions latest
         WHERE latest.pack_uid = pack_versions.pack_uid
       )
     ORDER BY pack_versions.updated_at DESC`
  )
    .bind(user.email)
    .all<PackRow>();

  const packs = [];
  for (const row of result.results) {
    packs.push(await rowToPack(db, row));
  }

  return json({ packs });
}

export async function getPackDraft(env: SpellbookEnv, user: DatabaseUser, uid: string): Promise<Response> {
  const db = requireDatabase(env);
  const latest = await findLatestPack(db, uid);

  if (!latest) {
    throw new AppError("Pack not found.", 404);
  }

  if (latest.owner_email !== user.email) {
    throw new AppError("Only the creator can read this pack draft.", 403);
  }

  return json({ pack: await rowToPack(db, latest) });
}

export async function getPackVersion(
  env: SpellbookEnv,
  uid: string,
  version: number,
  viewer: DatabaseUser | null
): Promise<Response> {
  if (!Number.isInteger(version) || version < 1) {
    throw new AppError("Pack not found.", 404);
  }

  const db = requireDatabase(env);
  const pack = await findPackVersion(db, uid, version);
  if (!pack || (pack.state !== "approved" && pack.owner_email !== viewer?.email)) {
    throw new AppError("Pack not found.", 404);
  }

  return json({ pack: await rowToPack(db, pack) });
}

export async function reviewPackVersion(
  env: SpellbookEnv,
  admin: DatabaseUser,
  uid: string,
  version: number,
  action: "approved" | "needs_changes",
  notes: string | null
): Promise<Response> {
  const db = requireDatabase(env);
  const pack = await findPackVersion(db, uid, version);

  if (!pack) {
    throw new AppError("Pack not found.", 404);
  }

  if (pack.state !== "submitted_for_review") {
    throw new AppError("Only submitted packs can be reviewed.", 409);
  }

  const refs = await getPackRules(db, uid, version);
  const now = nowIso();

  if (action === "approved") {
    const invalid = refs.find((ref) => ref.state !== "approved" && ref.included_draft_rule !== 1);
    if (invalid) {
      throw new AppError("Approved packs can only point at approved rule versions.", 409);
    }

    await db.batch([
      db.prepare(
        `UPDATE pack_versions
         SET state = 'approved', approved_at = ?, reviewed_at = ?, reviewer_email = ?, review_notes = ?, updated_at = ?
         WHERE pack_uid = ? AND version = ?`
      )
        .bind(now, now, admin.email, notes, now, uid, version),
      ...refs
        .filter((ref) => ref.included_draft_rule === 1)
        .map((ref) =>
          db.prepare(
            `UPDATE rule_versions
             SET state = 'approved', approved_at = ?, reviewed_at = ?, reviewer_email = ?, review_notes = ?, updated_at = ?
             WHERE rule_uid = ? AND version = ? AND state = 'submitted_for_review'`
          )
            .bind(now, now, admin.email, notes, now, ref.rule_uid, ref.rule_version)
        ),
      db.prepare(
        `INSERT INTO review_events (id, artifact_type, artifact_uid, artifact_version, action, actor_email, notes, created_at)
         VALUES (?, 'pack', ?, ?, 'approved', ?, ?, ?)`
      )
        .bind(crypto.randomUUID(), uid, version, admin.email, notes, now)
    ]);

    await assertApprovedPackRules(db, uid, version);
    return json({ pack: await getPackResponse(db, uid, version) });
  }

  const requiredNotes = requireReviewNotes(notes);
  await db.batch([
    db.prepare(
      `UPDATE pack_versions
       SET state = 'needs_changes', reviewed_at = ?, reviewer_email = ?, review_notes = ?, updated_at = ?
       WHERE pack_uid = ? AND version = ?`
    )
      .bind(now, admin.email, requiredNotes, now, uid, version),
    ...refs
      .filter((ref) => ref.included_draft_rule === 1)
      .map((ref) =>
        db.prepare(
          `UPDATE rule_versions
           SET state = 'needs_changes', reviewed_at = ?, reviewer_email = ?, review_notes = ?, updated_at = ?
           WHERE rule_uid = ? AND version = ? AND state = 'submitted_for_review'`
        )
          .bind(now, admin.email, requiredNotes, now, ref.rule_uid, ref.rule_version)
      ),
    db.prepare(
      `INSERT INTO review_events (id, artifact_type, artifact_uid, artifact_version, action, actor_email, notes, created_at)
       VALUES (?, 'pack', ?, ?, 'needs_changes', ?, ?, ?)`
    )
      .bind(crypto.randomUUID(), uid, version, admin.email, requiredNotes, now)
  ]);

  return json({ pack: await getPackResponse(db, uid, version) });
}

async function validatePackRuleRefs(
  db: D1Database,
  refs: PackRuleRef[],
  ownerEmail: string
): Promise<ValidatedPackRuleRef[]> {
  if (refs.length === 0) {
    throw new AppError("Packs must include at least one rule.", 400);
  }

  const validated: ValidatedPackRuleRef[] = [];
  const seen = new Set<string>();

  for (const ref of refs) {
    const key = `${ref.uid}:${ref.version}`;
    if (seen.has(key)) {
      throw new AppError("A pack cannot include the same rule version twice.", 400);
    }
    seen.add(key);

    const rule = await findRuleVersion(db, ref.uid, ref.version, ownerEmail);
    if (!rule) {
      throw new AppError("One of the pack rules was not found.", 404);
    }

    if (rule.state === "approved") {
      validated.push({ ...ref, includedDraftRule: false });
      continue;
    }

    if (rule.owner_email !== ownerEmail) {
      throw new AppError("Packs can only include another creator's approved rules.", 403);
    }

    if (!isMutableRuleState(rule.state)) {
      throw new AppError("One of the pack rules cannot be submitted.", 409);
    }

    validated.push({ ...ref, includedDraftRule: true });
  }

  return validated;
}

async function findLatestPack(db: D1Database, uid: string): Promise<PackRow | null> {
  return db.prepare(
    `${packSelectSql()}
     WHERE packs.uid = ?
     ORDER BY pack_versions.version DESC
     LIMIT 1`
  )
    .bind(uid)
    .first<PackRow>();
}

async function findPackVersion(db: D1Database, uid: string, version: number): Promise<PackRow | null> {
  return db.prepare(
    `${packSelectSql()}
     WHERE packs.uid = ? AND pack_versions.version = ?
     LIMIT 1`
  )
    .bind(uid, version)
    .first<PackRow>();
}

async function getPackResponse(db: D1Database, uid: string, version: number): Promise<PackResponse> {
  const row = await findPackVersion(db, uid, version);
  if (!row) {
    throw new AppError("Pack not found.", 404);
  }

  return rowToPack(db, row);
}

async function rowToPack(db: D1Database, row: PackRow): Promise<PackResponse> {
  const refs = await getPackRules(db, row.uid, row.version);

  return {
    uid: row.uid,
    version: row.version,
    lifecycleState: row.state,
    name: row.name,
    description: row.description,
    audience: row.audience,
    suggestedWorkspaceType: row.suggested_workspace_type,
    compatibility: parseCompatibility(row.compatibility_json),
    releaseNotes: row.release_notes,
    ownerEmail: row.owner_email,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    submittedAt: row.submitted_at,
    approvedAt: row.approved_at,
    reviewedAt: row.reviewed_at,
    reviewerEmail: row.reviewer_email,
    reviewNotes: row.review_notes,
    rules: refs.map((ref) => ({
      uid: ref.rule_uid,
      version: ref.rule_version,
      lifecycleState: ref.state,
      name: ref.name,
      ownerEmail: ref.owner_email,
      includedDraftRule: ref.included_draft_rule === 1
    }))
  };
}

async function getPackRules(db: D1Database, uid: string, version: number): Promise<PackRuleRow[]> {
  const result = await db.prepare(
    `SELECT
       pack_version_rules.rule_uid,
       pack_version_rules.rule_version,
       pack_version_rules.included_draft_rule,
       pack_version_rules.position,
       rule_versions.state,
       rule_versions.name,
       rules.owner_email
     FROM pack_version_rules
     JOIN rule_versions
       ON rule_versions.rule_uid = pack_version_rules.rule_uid
      AND rule_versions.version = pack_version_rules.rule_version
     JOIN rules ON rules.uid = rule_versions.rule_uid
     WHERE pack_version_rules.pack_uid = ?
       AND pack_version_rules.pack_version = ?
     ORDER BY pack_version_rules.position ASC`
  )
    .bind(uid, version)
    .all<PackRuleRow>();

  return result.results;
}

async function getExistingPackRuleRefs(
  db: D1Database,
  uid: string,
  version: number
): Promise<ValidatedPackRuleRef[]> {
  const refs = await getPackRules(db, uid, version);
  return refs.map((ref) => ({
    uid: ref.rule_uid,
    version: ref.rule_version,
    includedDraftRule: ref.included_draft_rule === 1
  }));
}

function packRuleStatements(
  db: D1Database,
  uid: string,
  version: number,
  refs: ValidatedPackRuleRef[]
): D1PreparedStatement[] {
  return refs.map((ref, index) =>
    db.prepare(
      `INSERT INTO pack_version_rules (
         pack_uid, pack_version, rule_uid, rule_version, position, included_draft_rule
       )
       VALUES (?, ?, ?, ?, ?, ?)`
    )
      .bind(uid, version, ref.uid, ref.version, index, ref.includedDraftRule ? 1 : 0)
  );
}

async function assertApprovedPackRules(db: D1Database, uid: string, version: number): Promise<void> {
  const invalid = await db.prepare(
    `SELECT COUNT(*) AS count
     FROM pack_version_rules
     JOIN rule_versions
       ON rule_versions.rule_uid = pack_version_rules.rule_uid
      AND rule_versions.version = pack_version_rules.rule_version
     WHERE pack_version_rules.pack_uid = ?
       AND pack_version_rules.pack_version = ?
       AND rule_versions.state <> 'approved'`
  )
    .bind(uid, version)
    .first<{ count: number }>();

  if ((invalid?.count ?? 0) > 0) {
    throw new AppError("Approved packs can only point at approved rule versions.", 409);
  }
}

function packSelectSql(): string {
  return `SELECT
            packs.uid,
            packs.owner_email,
            pack_versions.version,
            pack_versions.state,
            pack_versions.name,
            pack_versions.description,
            pack_versions.audience,
            pack_versions.suggested_workspace_type,
            pack_versions.compatibility_json,
            pack_versions.release_notes,
            pack_versions.created_at,
            pack_versions.updated_at,
            pack_versions.submitted_at,
            pack_versions.approved_at,
            pack_versions.reviewed_at,
            pack_versions.reviewer_email,
            pack_versions.review_notes
          FROM packs
          JOIN pack_versions ON pack_versions.pack_uid = packs.uid`;
}

function parsePackInput(body: Record<string, unknown>): PackInput {
  return {
    name: requiredText(body.name, "Name is required.", 120),
    description: requiredText(body.description, "Description is required.", 1000),
    audience: requiredText(body.audience, "Audience is required.", 500),
    suggestedWorkspaceType: requiredText(body.suggestedWorkspaceType, "Suggested workspace type is required.", 160),
    compatibility: parseCompatibilityInput(body.compatibility),
    releaseNotes: optionalText(body.releaseNotes, 2000) ?? "",
    rules: parseRuleRefs(body.rules)
  };
}

function parsePackPatch(body: Record<string, unknown>): PackPatch {
  const patch: PackPatch = {};

  if (body.name !== undefined) {
    patch.name = requiredText(body.name, "Name is required.", 120);
  }
  if (body.description !== undefined) {
    patch.description = requiredText(body.description, "Description is required.", 1000);
  }
  if (body.audience !== undefined) {
    patch.audience = requiredText(body.audience, "Audience is required.", 500);
  }
  if (body.suggestedWorkspaceType !== undefined) {
    patch.suggestedWorkspaceType = requiredText(body.suggestedWorkspaceType, "Suggested workspace type is required.", 160);
  }
  if (body.compatibility !== undefined) {
    patch.compatibility = parseCompatibilityInput(body.compatibility);
  }
  if (body.releaseNotes !== undefined) {
    patch.releaseNotes = optionalText(body.releaseNotes, 2000) ?? "";
  }
  if (body.rules !== undefined) {
    patch.rules = parseRuleRefs(body.rules);
  }

  if (Object.keys(patch).length === 0) {
    throw new AppError("Send at least one pack field to update.", 400);
  }

  return patch;
}

function mergePackInput(row: PackRow, patch: PackPatch): Omit<PackInput, "rules"> {
  return {
    name: patch.name ?? row.name,
    description: patch.description ?? row.description,
    audience: patch.audience ?? row.audience,
    suggestedWorkspaceType: patch.suggestedWorkspaceType ?? row.suggested_workspace_type,
    compatibility: patch.compatibility ?? parseCompatibility(row.compatibility_json),
    releaseNotes: patch.releaseNotes ?? row.release_notes
  };
}

function parseRuleRefs(value: unknown): PackRuleRef[] {
  if (!Array.isArray(value)) {
    throw new AppError("Pack rules must be an array.", 400);
  }

  return value.map((entry) => {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      throw new AppError("Each pack rule must include a uid and version.", 400);
    }

    const record = entry as Record<string, unknown>;
    const uid = requiredText(record.uid, "Each pack rule must include a uid.", 160);
    const version = Number(record.version);
    if (!Number.isInteger(version) || version < 1) {
      throw new AppError("Each pack rule version must be a positive integer.", 400);
    }

    return { uid, version };
  });
}

function parseCompatibilityInput(value: unknown): Record<string, unknown> {
  if (value === undefined || value === null) {
    return {};
  }

  if (typeof value !== "object" || Array.isArray(value)) {
    throw new AppError("Compatibility metadata must be an object.", 400);
  }

  return value as Record<string, unknown>;
}

function parseCompatibility(value: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(value);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return {};
  }

  return parsed as Record<string, unknown>;
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
    throw new AppError("One of the pack fields has the wrong type.", 400);
  }

  const text = value.trim();
  if (text.length === 0) {
    return null;
  }

  if (text.length > maxLength) {
    throw new AppError("One of the pack fields is too long.", 400);
  }

  return text;
}

function requireReviewNotes(notes: string | null): string {
  const text = optionalText(notes, 5000);
  if (!text) {
    throw new AppError("Review notes are required when requesting changes.", 400);
  }

  return text;
}
