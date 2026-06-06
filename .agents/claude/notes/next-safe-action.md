# next-safe-action patterns

Applies to riben.life, mingster.com, pstv. All use next-safe-action v8.

## Two-file convention

Every mutation lives in two sibling files:

```
src/actions/{domain}/{verb}-{object}.ts
src/actions/{domain}/{verb}-{object}.validation.ts
```

Read-only fetchers are plain `async` functions in the same domain folder — no `.validation.ts`,
no safe-action wrapper needed.

## Validation file

```typescript
// {verb}-{object}.validation.ts
import { z } from "zod";

export const verbObjectSchema = z.object({
  id: z.string(),
  // ...fields
});

export type VerbObjectInput = z.infer<typeof verbObjectSchema>;
```

- Zod v4: `import { z } from "zod"` (not `zod/v4`).
- Export both schema and inferred type.
- Reuse the schema in the form component — never duplicate it.

## Action clients

| Client | Use for |
|--------|---------|
| `storeActionClient` | Store-admin mutations (storeId required) |
| `userRequiredActionClient` | Any authenticated-user mutation |
| `adminActionClient` | sysAdmin mutations |
| `baseClient` | Public / unauthenticated mutations |

Import from `@/utils/actions/safe-action`.

## storeActionClient: storeId is a bound arg

`storeId` is the first bound argument — it is NOT part of the Zod schema.

```typescript
// action definition
export const upsertThingAction = storeActionClient
  .metadata({ name: "upsertThing" })
  .schema(upsertThingSchema)
  .action(async ({ parsedInput, bindArgsClientInputs }) => {
    const storeId = bindArgsClientInputs[0] as string;
    // ...
  });

// call site
const result = await upsertThingAction(storeId, { id, name });
```

## Timestamps in actions

```typescript
import { getUtcNowEpoch } from "@/utils/datetime-utils";
const now = getUtcNowEpoch();
// createdOn: now, updatedOn: now
```

## User-facing errors

```typescript
import { SafeError } from "@/utils/error";
throw new SafeError(await getT("i18n_key"));
```

`SafeError` surfaces as `result.serverError` on the client. Generic `Error` becomes a
generic "Something went wrong" message.

## Checklist

- [ ] `"use server"` at top of action file
- [ ] Schema in `.validation.ts`, not in the action file
- [ ] `storeId` from `bindArgsClientInputs[0]`, not from schema
- [ ] `metadata({ name: "..." })` on every action
- [ ] `getUtcNowEpoch()` for all timestamps
- [ ] `transformPrismaDataForJson()` if result contains BigInt/Decimal
- [ ] `SafeError` for user-facing error messages
