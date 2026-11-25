# head-checks tsc cache

`script/head-checks-tsc.sh` keeps one incremental tsc cache per host and repo, in
`~/orca/workspaces/<repo>/tsc-cache/`. Every check worktree of that repo uses it, so a new
worktree does not pay a full tsc run.

* **Key.** A hash of the lockfiles (`bun.lock`, `bun.lockb`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`) and every `tsconfig*.json`. The file is `<key>.tsbuildinfo`.
* **Key change.** No file matches, so tsc runs in full. When it finishes, the new file replaces the old one.
* **Concurrent runs.** Each run works on a private copy and publishes it with an atomic rename. Two runs at once leave one whole file.
* **Time limit.** `HEAD_CHECKS_TSC_TIMEOUT_SECONDS` sets how long one tsc run may take. The default is `600` seconds. tsc runs in its own process group. On expiry the whole group is stopped, the private copy is dropped, the shared cache is not published, and the script exits `124`. The variable must be a whole number above 0. Each check run keeps its own process group, so a hung tsc cannot hold memory for hours.
* **Why the copy sits in `node_modules/.cache/head-checks-tsc/`.** tsc stores paths relative to the cache file. A copy at the same depth in each worktree keeps those paths equal, so the cache hits. A copy beside a differently named worktree missed in testing.

Tests: `script/head-checks-tsc-cache.test.ts` (hit, key change, concurrent run, failing tsc, time limit).
