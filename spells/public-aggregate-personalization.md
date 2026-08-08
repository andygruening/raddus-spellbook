# Public aggregate personalization

Role: Software Developer

Category: Public aggregate personalization

## Requirement

Public aggregate features such as stars, votes, likes, or installs must separate anonymous aggregate counts from authenticated viewer-specific state.

## Trigger

Use this review lens for public registries, social or reaction features, optional-auth public endpoints, or UI that shows whether the current user has acted on a public item.

## Safe path

Keep public reads usable without auth, include viewer-specific booleans only when a valid session is supplied, enforce authenticated mutation endpoints with unique per-user records, and verify count plus current-user state update together after each mutation.
