# Cursor rules index (riben.life)

Repo-wide conventions live in the root `AGENTS.md`, which Cursor and Claude Code both load. These rules add detail for specific files. **Always-applied** rules load in every chat; **glob** rules load when a matching file is open. Learned facts that are not a coding rule live in `docs/agents/learned.md`.

## Always applied (keep short)

| File | Topic |
|------|-------|
| `doc-vault-context.mdc` | The `docs/` vault, the delivery lifecycle (ADR 0055), what to update on ship |
| `github.mdc` | Commit only when asked; `gh`; `CHANGELOG.md` on ship |
| `mobile-optimization.mdc` | Mobile-first requirement and touch/layout patterns |

## Loaded by file pattern or on request

| File | Topic |
|------|-------|
| `actions-vs-lib.mdc` | Where code goes: `actions/`, `lib/`, `utils/`, `hooks/`, `types/`; `"use server"` rules |
| `server-actions.mdc` | next-safe-action clients and conventions |
| `zod-v4.mdc` | Zod v4 schemas in `*.validation.ts` |
| `form-handling.mdc` | React Hook Form, Zod and shadcn Form |
| `crud-guide.mdc` | Store admin CRUD pages (list, columns, row actions, edit dialog) |
| `import-export-pattern.mdc` | JSON import/export for store admin resources |
| `data-fetching.mdc` | Server fetching, SWR in clients, async Next.js request APIs |
| `web-app-routing.mdc` | Store admin layout rules |
| `web-prisma.mdc` | Prisma schema, client generation, `db push`, datetimes |
| `logging.mdc` | `logger` usage |
| `i18n-naming.mdc` | Translation key naming |
| `icon-library.mdc` | Tabler icons |
| `tailwind.mdc` | Tailwind CSS v4 |
| `build-execution.mdc` | When to run `bun run build` |
| `cursor-rules.mdc` | How to add or change a rule |

## Repo skills

Longer, task-shaped guidance lives in `.cursor/skills/<name>/SKILL.md` (symlinked from `.claude/skills/`): `action-scaffold`, `store-admin-crud`, `e2e-test-scaffold`, `i18n-sync`, `payment-plugin`, `shadcn`.
