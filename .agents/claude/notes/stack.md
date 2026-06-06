# Common stack

All active web projects share this stack.

## Package manager

Bun only. Never npm, yarn, or pnpm. Use `bun add`, `bun install`, `bun run`.
Commit `bun.lock` on dependency changes.

## Core dependencies (current versions, 2026-06)

| Package | Version |
|---------|---------|
| Next.js | 16.x (App Router) |
| React | 19 |
| TypeScript | strict |
| Prisma + @prisma/client | 7.x |
| better-auth | 1.6.x |
| next-safe-action | 8.5.x |
| Zod | 4.x (`import { z } from "zod"`, not `zod/v4`) |
| SWR | 2.4.x |
| Pino | 10.x |
| Tailwind CSS | v4 (CSS-first config via `@theme`) |
| shadcn/ui | Radix UI primitives |
| Biome | linting + formatting |
| react-hook-form | + zod resolver |

## TypeScript conventions

- `interface` over `type`
- const maps over enums
- `satisfies` for type validation
- Named exports preferred over default
- `@/` alias for all `src/` imports
- Avoid duplicate global `interface` names across `.tsx` files (TypeScript merges them and silently breaks component prop types)

## i18n

Locales: `tw` (default), `en`, `jp`. Keys are snake_case. Never hardcode user-facing strings.

Server component:
```typescript
import { getT } from "@/app/i18n";
const { t } = await getT(locale, "translation");
```

Client component:
```typescript
import { useTranslation } from "react-i18next";
const { t } = useTranslation("translation");
```

## Logging

Never `console.log`. Always use structured logger:

```typescript
import logger from "@/lib/logger";
logger.info("Order created", { metadata: { orderId }, tags: ["order"] });
logger.error("Payment failed", { metadata: { error: err.message }, tags: ["payment", "error"] });
```

Utils that are imported by client components must NOT import `@/lib/logger` — it pulls Prisma
and Node.js APIs into the client bundle.

## Icons

`@tabler/icons-react` is primary (`IconPlus`, `IconTrash`, etc.). `lucide-react` is fallback only.

## shadcn/ui

`components/ui/` is shadcn-managed. Never edit those files directly. Wrap them instead.
