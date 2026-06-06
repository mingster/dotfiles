# Prisma patterns

Applies to riben.life, mingster.com, pstv.

## Datetime: BigInt epoch milliseconds

All projects store datetimes as `BigInt` epoch milliseconds. Never use Prisma `DateTime` fields
or `@default(now())`.

```typescript
import { getUtcNowEpoch, epochToDate } from "@/utils/datetime-utils";

// On create/update
createdOn: getUtcNowEpoch(),
updatedOn: getUtcNowEpoch(),

// To display
epochToDate(record.createdOn).toLocaleDateString()
```

pstv uses `getUtcNow()` from `@/utils/utils` — same concept, different import path.

## Serialize before sending to client

Prisma results containing `BigInt` or `Decimal` must be converted before passing to client
components or returning from server actions:

```typescript
import { transformPrismaDataForJson } from "@/utils/utils";
return transformPrismaDataForJson(result);
```

Forgetting this causes `TypeError: Do not know how to serialize a BigInt` at runtime.

## No @prisma/client in client components

Never import from `@prisma/client` in `"use client"` modules. For role enums and shared types,
re-export from `@/types/enum` (riben.life) or equivalent local types file.

## Prisma singleton

The client is a singleton exported as `sqlClient` from `@/lib/prismadb`. Do not instantiate
`new PrismaClient()` anywhere else.

## After schema changes

```bash
bun run sql:generate   # riben.life / mingster.com
bun run generate       # pstv
```

Always regenerate before running — stale generated client causes type errors that look like schema
mismatches.

## Multiple schemas (pstv)

pstv has four isolated Prisma schemas:

| Schema | Domain |
|--------|--------|
| `prisma-pstv/` | Core platform (users, subscriptions, billing) |
| `prisma-epg/` | Electronic Program Guide |
| `prisma-enterprise/` | Enterprise / TV cards |
| `prisma-viewLog/` | Analytics and session logs |

Generated clients live in `src/lib/generated/`. `bun run migrate` runs migrations across all
schemas; `bun run generate` regenerates all clients.

## Lodash (when used)

Import Lodash functions individually to avoid bundling the whole library:

```typescript
import groupBy from "lodash/groupBy";
import sortBy from "lodash/sortBy";
```
