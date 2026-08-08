import { describe, expect, it } from "vitest";
import { parseSpellInput, rowToSpell } from "../src/spells";

describe("spell helpers", () => {
  it("parses markdown-backed spell input", () => {
    expect(
      parseSpellInput({
        name: "Review Boundaries",
        description: "Keep review feedback scoped to the requested change.",
        tags: ["Review", " review ", "scope"],
        file: "spells/review-boundaries.md",
        content: "# Review Boundaries\n\nCheck ownership and scope."
      })
    ).toEqual({
      uid: null,
      name: "Review Boundaries",
      description: "Keep review feedback scoped to the requested change.",
      tags: ["review", "scope"],
      file: "spells/review-boundaries.md",
      content: "# Review Boundaries\n\nCheck ownership and scope."
    });
  });

  it("rejects files outside the spells directory", () => {
    expect(() =>
      parseSpellInput({
        name: "Bad Path",
        description: "Do not allow path traversal.",
        tags: ["review"],
        file: "../bad.md",
        content: "# Bad Path"
      })
    ).toThrow("Spell files must live under ./spells and end in .md.");
  });

  it("maps D1 rows to uid-based spell responses", () => {
    expect(
      rowToSpell({
        id: "uid-123",
        name: "Review Boundaries",
        description: "Keep review feedback scoped.",
        file: "spells/review-boundaries.md",
        content: "# Review Boundaries",
        tags_json: "[\"review\"]",
        owner_email: "ada@example.com",
        published: 1,
        created_at: "2026-08-06T00:00:00.000Z",
        updated_at: "2026-08-06T00:00:00.000Z",
        published_at: "2026-08-06T00:00:00.000Z",
        star_count: 3,
        starred_by_viewer: 1
      })
    ).toEqual({
      uid: "uid-123",
      name: "Review Boundaries",
      description: "Keep review feedback scoped.",
      tags: ["review"],
      file: "spells/review-boundaries.md",
      content: "# Review Boundaries",
      ownerEmail: "ada@example.com",
      publishedAt: "2026-08-06T00:00:00.000Z",
      starCount: 3,
      starredByMe: true
    });
  });
});
