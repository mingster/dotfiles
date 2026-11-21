# head-checks tsc cache

`script/head-checks-tsc.sh` keeps one incremental tsc cache per host and repo, in
`~/orca/workspaces/<repo>/tsc-cache/`. Every check worktree of that repo uses it, so a new
worktree does not pay a full tsc run.

* **Key.** A hash of the lockfiles (`bun.lock`, `bun.lockb`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`) and every `tsconfig*.json`. The file is `<key>.tsbuildinfo`.
* **Key change.** No file matches, so tsc runs in full. When it finishes, the new file replaces the old one.
* **Concurrent runs.** Each run works on a private copy and publishes it with an atomic rename. Two runs at once leave one whole file.
* **Why the copy sits in `node_modules/.cache/head-checks-tsc/`.** tsc stores paths relative to the cache file. A copy at the same depth in each worktree keeps those paths equal, so the cache hits. A copy beside a differently named worktree missed in testing.

Tests: `script/head-checks-tsc-cache.test.ts` (hit, key change, concurrent run, failing tsc).
