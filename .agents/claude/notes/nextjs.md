# Next.js App Router patterns

Applies to riben.life, mingster.com, pstv.

## Data fetching rule

- Server components: fetch directly with Prisma (no SWR, no useEffect)
- Client components: SWR for reads (`useSWR<T>("/api/...")`)
- All mutations: Next.js Server Actions via next-safe-action

## After mutations: update state directly

Never use `router.refresh()` to sync list data after a mutation. Update local `useState` directly
from the action return value. `router.refresh()` causes a full server round-trip and resets scroll
position.

```typescript
const result = await upsertThingAction(storeId, values);
if (result?.serverError) { toastError(result.serverError); return; }
onUpdated(result.data as ThingColumn);
```

## Route group layout gotcha

A route group `(foo)` can only have one `layout.tsx`. Adding a nested `(routes)/layout.tsx` under
an existing `(dashboard)/layout.tsx` causes silent dev 404s on all child routes. Verified in
riben.life `storeAdmin/(dashboard)/[storeId]/`.

## Async API — must be awaited

These Next.js APIs are async in v15+. Forgetting to await is a runtime error:

```typescript
const { storeId } = await params;         // props.params
const { q } = await searchParams;         // props.searchParams
const cookieStore = await cookies();
const headersList = await headers();
```

## CRUD admin page pattern

Consistent across all three projects:

```
page.tsx                        server component — fetch Prisma rows, map to Column type, render client
components/client-{feature}.tsx  "use client" — useState array, define columns, callbacks
components/edit-{feature}-dialog.tsx  react-hook-form + Zod; calls action; fires callback
```

The Column type lives in `{feature}-column.ts` (plain TS, no React, no BigInt, no Prisma types).
Server page converts BigInt timestamps to strings before passing to client.
Callbacks (`onCreated`, `onUpdated`, `onDeleted`) update state; never `router.refresh()`.
`useCallback` stabilizes handlers; `useMemo` wraps column factory.

Reference: `src/app/storeAdmin/(dashboard)/[storeId]/(routes)/product-option-template/` (riben.life)

## Select empty value

Use `"--"` (not `""`) as the empty/placeholder option value. Map `"--"` to `null` in
`onValueChange`. An empty string breaks Radix Select's controlled state.

## Tailwind v4

CSS-first config: no `tailwind.config.ts`. Tokens defined via `@theme` in CSS.
CSS variables referenced as `bg-(--brand-color)` (not `bg-[var(--brand-color)]`).

## Error handling in server actions

```typescript
if (result?.serverError) {
  toastError({ description: result.serverError });
  return;
}
toastSuccess({ description: "Saved!" });
```

Use `SafeError` (not generic `Error`) for user-facing messages inside actions so next-safe-action
surfaces the message as `serverError` instead of a generic string.
