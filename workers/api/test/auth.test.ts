import { describe, expect, it } from "vitest";
import { constantTimeEqual, generateOtpCode, hashOtp, normalizeEmail, signJwt, verifyJwt } from "../src/auth";

describe("auth helpers", () => {
  it("normalizes valid emails", () => {
    expect(normalizeEmail("  Ada@Example.COM ")).toBe("ada@example.com");
  });

  it("generates six-digit OTP codes", () => {
    expect(generateOtpCode()).toMatch(/^\d{6}$/);
  });

  it("hashes OTPs deterministically with a salt and secret", async () => {
    const first = await hashOtp("ada@example.com", "123456", "salt", "secret");
    const second = await hashOtp("ada@example.com", "123456", "salt", "secret");
    const third = await hashOtp("ada@example.com", "654321", "salt", "secret");

    expect(await constantTimeEqual(first, second)).toBe(true);
    expect(await constantTimeEqual(first, third)).toBe(false);
  });

  it("signs and verifies JWT sessions", async () => {
    const { token } = await signJwt("ada@example.com", "a long enough local test secret", 1_700_000_000_000);
    await expect(verifyJwt(token, "a long enough local test secret", 1_700_000_001_000)).resolves.toEqual({
      email: "ada@example.com"
    });
  });

  it("rejects expired JWT sessions", async () => {
    const { token } = await signJwt("ada@example.com", "a long enough local test secret", 1_700_000_000_000);
    await expect(verifyJwt(token, "a long enough local test secret", 1_800_000_000_000)).rejects.toThrow(
      "Your session expired. Sign in again."
    );
  });
});
