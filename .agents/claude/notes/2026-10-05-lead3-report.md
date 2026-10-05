# Lead3 report (2026-10-05)

## PRs merged
- web2 #930: get-pin-result throttle, counting mode (#852 part 1). secops B1 (object deviceId) and B2 (map fail closed) fixed.
- web2 #931: jellyfin-config deviceId string guard (merged after conflict fix with main).
- web2 #933: jellyfin-config per address limit, counting mode (#795). secops B2 fixed.
- web2 #934: AGENTS.md note, bun run generate needs DATABASE_URL_*.
- fileServer #93: learned.md note on the same gotcha.
- pstv (root) #27: AGENTS.md says fileServer default branch is main.

## PRs open
- web2 #932 (base production): deviceId string guard hotfix for get-pin-result and jellyfin-config. qa-sdet and secops-finops approved. Waits on the owner's go and release-manager. Worktree web2-hotfix kept.

## Issues
- Android #155: closed, already on main via PR #168 (513 clears ids, SESSION_REVOKED keeps them). Gap: DEVICE_ROW test does not assert session and appid cleared (optional small test).
- web2 #852: kept open, relabelled ready-for-human (enforce flip needs deploy, counts read, Roku 5.9 polling check). Also tracks the #795 enforce flip.
- web2 #795: closed by #933, comment points to #852.

## Needs owner
1. Go for production hotfix #932 (both routes accept object deviceId on production today; prefix enumeration of serials).
2. Later: enforce flip decisions for PIN_RESULT_THROTTLE_MODE and JELLYFIN_CONFIG_THROTTLE_MODE after counts are read.
3. Decide whether #930 and #933 reach production by a release or a cherry pick (#930 cannot cherry pick, older code).

## Findings
- Sibling route audit: no other route lets a non string reach a Prisma where (main and production). get-pin on production only reaches create data, but echoes the Prisma error at route.ts:63.
- Orca nested worker depth is 1, so the Tech Lead could not start workers; Elon dispatched from my specs.
- Worktree arm-848 belongs to another lane, untouched.
