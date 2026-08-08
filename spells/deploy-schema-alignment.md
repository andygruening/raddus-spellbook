# Deploy Schema Alignment

**Role:** DevOps Engineer

**Category:** Deployment and schema readiness

## Requirement

When backend code depends on a changed database schema, verify the deployed production code version and the bound database migration state together.

## Trigger

Use this when a production API reports missing tables or columns after migrations were supposedly applied, or when deploying code that depends on a new migration.

## Safe Path

Check the remote migration ledger, inspect the bound database schema, tail the deployed Worker logs with a failing request ID, and confirm the live Worker version was redeployed after schema-dependent code changed. Product-safe errors should mention deployment/schema drift instead of only telling users to re-run migrations.
