import type { DatabaseUser } from "./auth";
import { requireDatabase, type SpellbookEnv } from "./db";
import { AppError, json, readJsonObject } from "./http";
import { reviewPackVersion } from "./packs";
import { parseReviewNotes, reviewRuleVersion } from "./rules";

type ReviewQueueRow = {
  artifact_type: "rule" | "pack";
  uid: string;
  version: number;
  name: string;
  owner_email: string;
  submitted_at: string | null;
};

export async function listReviewQueue(env: SpellbookEnv): Promise<Response> {
  const db = requireDatabase(env);
  const result = await db.prepare(
    `SELECT 'rule' AS artifact_type, rules.uid, rule_versions.version, rule_versions.name,
            rules.owner_email, rule_versions.submitted_at
     FROM rules
     JOIN rule_versions ON rule_versions.rule_uid = rules.uid
     WHERE rule_versions.state = 'submitted_for_review'
     UNION ALL
     SELECT 'pack' AS artifact_type, packs.uid, pack_versions.version, pack_versions.name,
            packs.owner_email, pack_versions.submitted_at
     FROM packs
     JOIN pack_versions ON pack_versions.pack_uid = packs.uid
     WHERE pack_versions.state = 'submitted_for_review'
     ORDER BY submitted_at ASC`
  )
    .all<ReviewQueueRow>();

  return json({
    reviews: result.results.map((row) => ({
      artifactType: row.artifact_type,
      uid: row.uid,
      version: row.version,
      name: row.name,
      ownerEmail: row.owner_email,
      submittedAt: row.submitted_at
    }))
  });
}

export async function reviewRule(
  request: Request,
  env: SpellbookEnv,
  admin: DatabaseUser,
  uid: string,
  version: number,
  action: "approved" | "needs_changes"
): Promise<Response> {
  const notes = await notesFromRequest(request);
  return reviewRuleVersion(env, admin, uid, version, action, notes);
}

export async function reviewPack(
  request: Request,
  env: SpellbookEnv,
  admin: DatabaseUser,
  uid: string,
  version: number,
  action: "approved" | "needs_changes"
): Promise<Response> {
  const notes = await notesFromRequest(request);
  return reviewPackVersion(env, admin, uid, version, action, notes);
}

function parseVersion(value: string | undefined): number {
  const version = Number(value);
  if (!Number.isInteger(version) || version < 1) {
    throw new AppError("Review target not found.", 404);
  }

  return version;
}

export function parseReviewVersion(value: string | undefined): number {
  return parseVersion(value);
}

async function notesFromRequest(request: Request): Promise<string | null> {
  if (!request.headers.get("Content-Type") && request.body === null) {
    return null;
  }

  return parseReviewNotes(await readJsonObject(request));
}
