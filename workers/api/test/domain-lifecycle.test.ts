import { describe, expect, it } from "vitest";
import { hashOtp, signJwt } from "../src/auth";
import worker from "../src/index";
import { createTestD1 } from "./d1-test";

const secret = "a long enough local test secret";

describe("ADR-0003 rule and pack backend domain", () => {
  it("upserts a user record during OTP verification", async () => {
    const env = await testEnv();
    const email = "ada@example.com";
    const code = "123456";
    const salt = "otp-salt";
    const now = new Date().toISOString();
    const codeHash = await hashOtp(email, code, salt, secret);

    await env.DB.prepare(
      `INSERT INTO otp_challenges (id, email, code_hash, salt, expires_at, consumed_at, created_at)
       VALUES (?, ?, ?, ?, ?, NULL, ?)`
    )
      .bind("challenge-1", email, codeHash, salt, new Date(Date.now() + 60_000).toISOString(), now)
      .run();

    const response = await api(env, "POST", "/api/auth/verify-otp", undefined, { email, code });
    expect(response.status).toBe(200);
    expect((await response.json()) as { email: string; role: string }).toMatchObject({ email, role: "user" });

    const user = await env.DB.prepare("SELECT email, role FROM users WHERE email = ?")
      .bind(email)
      .first<{ email: string; role: string }>();
    expect(user).toEqual({ email, role: "user" });
  });

  it("keeps rule drafts private, requires admin review, and lists latest approved versions only", async () => {
    const env = await testEnv();
    const ada = await token("ada@example.com");
    const bob = await token("bob@example.com");
    const admin = await token("admin@example.com");
    await makeAdmin(env.DB, "admin@example.com");

    const created = await api(env, "POST", "/api/rules", ada, {
      name: "Review Boundaries",
      description: "Keep review feedback scoped.",
      appliesWhen: "Use when reviewing code changes.",
      body: "# Review Boundaries"
    });

    expect(created.status).toBe(201);
    const createdBody = await created.json() as RulePayload;
    const uid = createdBody.rule.uid;
    expect(createdBody.rule.lifecycleState).toBe("draft");

    expect(await expectRules(await api(env, "GET", "/api/rules/public"))).toEqual([]);

    const bobDraftRead = await api(env, "GET", `/api/rules/${uid}/draft`, bob);
    expect(bobDraftRead.status).toBe(403);

    const submitted = await api(env, "POST", `/api/rules/${uid}/submit`, ada);
    expect((await submitted.json() as RulePayload).rule.lifecycleState).toBe("submitted_for_review");

    const nonAdminReview = await api(env, "POST", `/api/admin/rules/${uid}/versions/1/approve`, bob, {});
    expect(nonAdminReview.status).toBe(403);

    const approved = await api(env, "POST", `/api/admin/rules/${uid}/versions/1/approve`, admin, {});
    const approvedBody = await approved.json() as RulePayload;
    expect(approvedBody.rule.lifecycleState).toBe("approved");
    expect(approvedBody.rule.version).toBe(1);

    const publicRules = await expectRules(await api(env, "GET", "/api/rules/public"));
    expect(publicRules).toHaveLength(1);
    expect(publicRules[0]?.uid).toBe(uid);
    expect(publicRules[0]?.version).toBe(1);

    const nextDraft = await api(env, "PATCH", `/api/rules/${uid}/draft`, ada, {
      body: "# Review Boundaries\n\nSecond version."
    });
    expect(nextDraft.status).toBe(201);
    const nextDraftBody = await nextDraft.json() as RulePayload;
    expect(nextDraftBody.rule.version).toBe(2);
    expect(nextDraftBody.rule.lifecycleState).toBe("draft");

    const latestPublic = await expectRules(await api(env, "GET", "/api/rules/public"));
    expect(latestPublic).toHaveLength(1);
    expect(latestPublic[0]?.version).toBe(1);
  });

  it("reviews packs atomically and keeps pack public listings latest-approved only", async () => {
    const env = await testEnv();
    const ada = await token("ada@example.com");
    const bob = await token("bob@example.com");
    const admin = await token("admin@example.com");
    await makeAdmin(env.DB, "admin@example.com");

    const approvedDependency = await createApprovedRule(env, bob, admin, "Careful Reviews");
    const draftIncludedRule = await createRule(env, ada, "No Surprise Changes");

    const packCreate = await api(env, "POST", "/api/packs", ada, {
      name: "Careful Code Assistant",
      description: "A pack for scoped, predictable coding work.",
      audience: "Software teams",
      suggestedWorkspaceType: "code",
      compatibility: { harnesses: ["AGENTS.md"] },
      releaseNotes: "Initial pack.",
      rules: [
        { uid: approvedDependency.uid, version: approvedDependency.version },
        { uid: draftIncludedRule.uid, version: draftIncludedRule.version }
      ]
    });
    expect(packCreate.status).toBe(201);
    const packUid = ((await packCreate.json()) as PackPayload).pack.uid;

    const submitted = await api(env, "POST", `/api/packs/${packUid}/submit`, ada);
    const submittedPack = (await submitted.json()) as PackPayload;
    expect(submittedPack.pack.lifecycleState).toBe("submitted_for_review");
    expect(submittedPack.pack.rules.find((rule) => rule.uid === draftIncludedRule.uid)?.lifecycleState)
      .toBe("submitted_for_review");

    const approved = await api(env, "POST", `/api/admin/packs/${packUid}/versions/1/approve`, admin, {
      notes: "Approved as a coherent pack."
    });
    const approvedPack = (await approved.json()) as PackPayload;
    expect(approvedPack.pack.lifecycleState).toBe("approved");
    expect(approvedPack.pack.rules.map((rule) => rule.lifecycleState)).toEqual(["approved", "approved"]);

    const publicPacks = await expectPacks(await api(env, "GET", "/api/packs/public"));
    expect(publicPacks).toHaveLength(1);
    expect(publicPacks[0]?.uid).toBe(packUid);
    expect(publicPacks[0]?.version).toBe(1);

    const nextPackDraft = await api(env, "PATCH", `/api/packs/${packUid}/draft`, ada, {
      releaseNotes: "Preparing a second version."
    });
    expect(nextPackDraft.status).toBe(201);

    const latestPublicPacks = await expectPacks(await api(env, "GET", "/api/packs/public"));
    expect(latestPublicPacks).toHaveLength(1);
    expect(latestPublicPacks[0]?.version).toBe(1);
  });

  it("keeps legacy spell endpoints rule-compatible", async () => {
    const env = await testEnv();
    const ada = await token("ada@example.com");
    const admin = await token("admin@example.com");
    await makeAdmin(env.DB, "admin@example.com");

    const created = await api(env, "POST", "/api/spells", ada, {
      name: "Legacy Compatible",
      description: "Create through the old spell endpoint.",
      trigger: "Use for old clients.",
      file: "instructions/legacy-compatible.md",
      content: "# Legacy Compatible"
    });
    expect(created.status).toBe(201);
    const createdSpell = (await created.json()) as SpellPayload;
    expect(createdSpell.spell.publishedAt).toBeNull();

    await api(env, "POST", `/api/rules/${createdSpell.spell.uid}/submit`, ada);
    await api(env, "POST", `/api/admin/rules/${createdSpell.spell.uid}/versions/1/approve`, admin, {});

    const publicSpells = await api(env, "GET", "/api/spells/public");
    const body = await publicSpells.json() as { spells: SpellPayload["spell"][] };
    expect(body.spells).toHaveLength(1);
    expect(body.spells[0]?.uid).toBe(createdSpell.spell.uid);
    expect(body.spells[0]?.trigger).toBe("Use for old clients.");
  });

  it("keeps new rule star and archive routes compatible with migrated spell behavior", async () => {
    const env = await testEnv();
    const ada = await token("ada@example.com");
    const bob = await token("bob@example.com");
    const admin = await token("admin@example.com");
    await makeAdmin(env.DB, "admin@example.com");

    const rule = await createApprovedRule(env, ada, admin, "Starred Rule");

    const starred = await api(env, "POST", `/api/rules/${rule.uid}/star`, bob);
    expect(starred.status).toBe(200);
    expect(((await starred.json()) as { rule: { starCount: number; starredByMe: boolean } }).rule)
      .toMatchObject({ starCount: 1, starredByMe: true });

    const unstarred = await api(env, "DELETE", `/api/rules/${rule.uid}/star`, bob);
    expect(unstarred.status).toBe(200);
    expect(((await unstarred.json()) as { rule: { starCount: number; starredByMe: boolean } }).rule)
      .toMatchObject({ starCount: 0, starredByMe: false });

    const archived = await api(env, "DELETE", `/api/rules/${rule.uid}`, ada);
    expect(archived.status).toBe(200);
    expect(await expectRules(await api(env, "GET", "/api/rules/public"))).toEqual([]);
  });
});

type RulePayload = {
  rule: {
    uid: string;
    version: number;
    lifecycleState: string;
  };
};

type PackPayload = {
  pack: {
    uid: string;
    version: number;
    lifecycleState: string;
    rules: Array<{
      uid: string;
      version: number;
      lifecycleState: string;
    }>;
  };
};

type SpellPayload = {
  spell: {
    uid: string;
    version: number;
    trigger: string;
    publishedAt: string | null;
  };
};

async function testEnv(): Promise<Env & { DB: D1Database; SPELLBOOK_JWT_SECRET: string }> {
  return {
    DB: createTestD1(),
    SPELLBOOK_JWT_SECRET: secret
  } as Env & { DB: D1Database; SPELLBOOK_JWT_SECRET: string };
}

async function token(email: string): Promise<string> {
  return (await signJwt(email, secret)).token;
}

async function makeAdmin(db: D1Database, email: string): Promise<void> {
  const now = new Date().toISOString();
  await db.prepare(
    `INSERT INTO users (email, role, created_at, updated_at)
     VALUES (?, 'admin', ?, ?)
     ON CONFLICT(email) DO UPDATE SET role = 'admin', updated_at = excluded.updated_at`
  )
    .bind(email, now, now)
    .run();
}

async function api(
  env: Env & { DB: D1Database; SPELLBOOK_JWT_SECRET: string },
  method: string,
  path: string,
  bearer?: string,
  body?: Record<string, unknown>
): Promise<Response> {
  const headers = new Headers();
  if (bearer) {
    headers.set("Authorization", `Bearer ${bearer}`);
  }
  if (body !== undefined) {
    headers.set("Content-Type", "application/json");
  }

  const init: RequestInit = { method, headers };
  if (body !== undefined) {
    init.body = JSON.stringify(body);
  }

  return worker.fetch(
    new Request(`https://spellbook-api.example.com${path}`, init),
    env,
    { waitUntil(_promise: Promise<unknown>) {} } as unknown as ExecutionContext
  );
}

async function expectRules(response: Response): Promise<Array<{ uid: string; version: number }>> {
  expect(response.status).toBe(200);
  return ((await response.json()) as { rules: Array<{ uid: string; version: number }> }).rules;
}

async function expectPacks(response: Response): Promise<Array<{ uid: string; version: number }>> {
  expect(response.status).toBe(200);
  return ((await response.json()) as { packs: Array<{ uid: string; version: number }> }).packs;
}

async function createRule(
  env: Env & { DB: D1Database; SPELLBOOK_JWT_SECRET: string },
  bearer: string,
  name: string
): Promise<{ uid: string; version: number }> {
  const response = await api(env, "POST", "/api/rules", bearer, {
    name,
    description: `${name} description.`,
    appliesWhen: `Use when ${name.toLowerCase()} applies.`,
    body: `# ${name}`
  });
  expect(response.status).toBe(201);
  return ((await response.json()) as RulePayload).rule;
}

async function createApprovedRule(
  env: Env & { DB: D1Database; SPELLBOOK_JWT_SECRET: string },
  owner: string,
  admin: string,
  name: string
): Promise<{ uid: string; version: number }> {
  const rule = await createRule(env, owner, name);
  await api(env, "POST", `/api/rules/${rule.uid}/submit`, owner);
  const approved = await api(env, "POST", `/api/admin/rules/${rule.uid}/versions/${rule.version}/approve`, admin, {});
  expect(approved.status).toBe(200);
  return rule;
}
