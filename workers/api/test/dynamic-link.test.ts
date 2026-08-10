import { describe, expect, it } from "vitest";
import worker from "../src/index";

describe("dynamic spell links", () => {
  it("redirects macOS requests to the Spellbook deeplink", async () => {
    const response = await worker.fetch(
      new Request("https://spellbook-api.example.com/open/spell-123", {
        headers: {
          "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15"
        }
      }),
      testEnv(),
      {} as ExecutionContext
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe("spellbook://spell/spell-123");
  });

  it("redirects non-macOS requests to the public web spell URL", async () => {
    const response = await worker.fetch(
      new Request("https://spellbook-api.example.com/open/spell-123", {
        headers: {
          "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
      }),
      testEnv(),
      {} as ExecutionContext
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe("https://spellbook.example.com/?spell=spell-123");
  });

  it("does not treat iPadOS desktop-class Safari as macOS", async () => {
    const response = await worker.fetch(
      new Request("https://spellbook-api.example.com/open/spell-123", {
        headers: {
          "User-Agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15) AppleWebKit/605.1.15 Mobile/15E148"
        }
      }),
      testEnv(),
      {} as ExecutionContext
    );

    expect(response.status).toBe(302);
    expect(response.headers.get("Location")).toBe("https://spellbook.example.com/?spell=spell-123");
  });
});

function testEnv(): Env & {
  SPELLBOOK_WEB_URL: string;
  SPELLBOOK_MACOS_DEEPLINK_SCHEME: string;
} {
  return {
    SPELLBOOK_WEB_URL: "https://spellbook.example.com",
    SPELLBOOK_MACOS_DEEPLINK_SCHEME: "spellbook"
  } as Env & {
    SPELLBOOK_WEB_URL: string;
    SPELLBOOK_MACOS_DEEPLINK_SCHEME: string;
  };
}
