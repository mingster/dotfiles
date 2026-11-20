# Release notes

What changed in this repository, one section per week, newest first. It is written for people who do not read code. Every number links to the pull request on GitHub. The full technical list is in [CHANGELOG.md](CHANGELOG.md), and [docs/changelog.md](docs/changelog.md) explains how that list is kept.

Words used below: the **team** is the group of AI agents that build software here. The **coordinator** is the agent that hands out work. A **worker** is an agent that does one task. A **verifier** is a second AI that checks finished work. The **fleet** is the group of computers the agents run on.

## Week of 2026-11-16 (so far)

### New

* Issues now carry one set of 20 labels (state, priority P0 to P3, size, role and hold labels). The team's watcher reads them to decide what to start first. Bugs are always P0. ([#1219](https://github.com/mingster/dotfiles/pull/1219))
* The watcher can run as a loop from the coordinator's own terminal, checking every 5 minutes. ([#1207](https://github.com/mingster/dotfiles/pull/1207))
* A new check lists leftover work folders whose pull request is already merged or closed. ([#1208](https://github.com/mingster/dotfiles/pull/1208))
* After a change to this repository is merged, every computer in the fleet pulls the new version by itself. ([#1175](https://github.com/mingster/dotfiles/pull/1175))
* Scripts that start work now update this repository first when it is safely behind. ([#1212](https://github.com/mingster/dotfiles/pull/1212))
* Idle workers that have an unread message get a nudge. ([#1140](https://github.com/mingster/dotfiles/pull/1140))
* A worker is refused when the issue it names was already closed by a merged pull request. ([#1165](https://github.com/mingster/dotfiles/pull/1165))
* Worker names now follow one form, the issue number, a bar and the role, so every card on the board is readable. ([#1183](https://github.com/mingster/dotfiles/pull/1183))
* A trial of one long running verifier per computer, off by default. ([#1227](https://github.com/mingster/dotfiles/pull/1227))
* The team's roles now check speed. The builder runs a performance list and the verifier fails work that skips it. ([#1181](https://github.com/mingster/dotfiles/pull/1181))
* A rule that tells agents to take the shortest path through a screen when they test it. ([#1143](https://github.com/mingster/dotfiles/pull/1143))
* Every role now prefers Claude, then Antigravity, then Grok, then Cursor. ([#1124](https://github.com/mingster/dotfiles/pull/1124))
* A provider can be paused until a chosen date. ([#1117](https://github.com/mingster/dotfiles/pull/1117))
* Pull requests that leave private names in the text are stopped before they are saved or merged. ([#1123](https://github.com/mingster/dotfiles/pull/1123))

### Changed in how the team works

* Work is spread across computers by how many workers each one already has, then by how busy it is. The computer that runs the coordinator is chosen last. Limits now scale with the number of processor cores and the free memory. ([#1132](https://github.com/mingster/dotfiles/pull/1132), [#1236](https://github.com/mingster/dotfiles/pull/1236), [#1232](https://github.com/mingster/dotfiles/pull/1232))
* One watcher pass now fills every free seat instead of starting a single issue. Issues for this repository go first. ([#1245](https://github.com/mingster/dotfiles/pull/1245), [#1241](https://github.com/mingster/dotfiles/pull/1241))
* When a verifier or a code review says a change failed, the watcher no longer starts an automatic rework. It tells the planner to redesign. Failed automatic checks that were caused by the computer, not the code, are simply rerun. ([#1210](https://github.com/mingster/dotfiles/pull/1210), [#1194](https://github.com/mingster/dotfiles/pull/1194))
* The watcher skips an issue that already has an open pull request. ([#1210](https://github.com/mingster/dotfiles/pull/1210))
* The slow parts of the usage limit check, the wrap up cleanup and the local test run were sped up. ([#1205](https://github.com/mingster/dotfiles/pull/1205), [#1206](https://github.com/mingster/dotfiles/pull/1206), [#1214](https://github.com/mingster/dotfiles/pull/1214))
* `ship.sh` stays the only way a change is merged. It now builds the diff itself when GitHub says it is too large, and it runs the private name check only on public repositories. ([#1164](https://github.com/mingster/dotfiles/pull/1164), [#1133](https://github.com/mingster/dotfiles/pull/1133))
* Docs: the database computer runs no browser tests, and regression tests run on the other computers. ([#1250](https://github.com/mingster/dotfiles/pull/1250))

### Fixed

* A worker that vanishes while starting is started once more, and mail to finished workers stops. ([#1225](https://github.com/mingster/dotfiles/pull/1225))
* A worker stuck on the Antigravity sign in screen is moved to Claude automatically. ([#1246](https://github.com/mingster/dotfiles/pull/1246))
* Finished work from a remote computer is now recognised and cleaned up. ([#1224](https://github.com/mingster/dotfiles/pull/1224), [#1229](https://github.com/mingster/dotfiles/pull/1229))
* A numbered list of acceptance points is now accepted in a brief. ([#1243](https://github.com/mingster/dotfiles/pull/1243))
* The pull request check accepts more ways of writing a test command. ([#1238](https://github.com/mingster/dotfiles/pull/1238))
* Apps install into the normal Applications folder again, and one helper finds them. ([#1249](https://github.com/mingster/dotfiles/pull/1249), [#1217](https://github.com/mingster/dotfiles/pull/1217))
* Automatic checks no longer report a false failure when the database computer is busy or has a stale install. ([#1193](https://github.com/mingster/dotfiles/pull/1193), [#1187](https://github.com/mingster/dotfiles/pull/1187))
* Cards on the board now show the right title and move to Done for every work folder of a shipped issue. ([#1185](https://github.com/mingster/dotfiles/pull/1185))

## Week of 2026-11-09

### New

* The team now works from pstack, a shared set of engineering skills, with our own rules on top. ([#835](https://github.com/mingster/dotfiles/pull/835))
* One command, `agent-team.sh`, sets up a computer or adopts the team in a project. ([#756](https://github.com/mingster/dotfiles/pull/756))
* The README was rewritten for people new to the team. ([#758](https://github.com/mingster/dotfiles/pull/758))
* A weekly audit with six checks and a printed report. ([#802](https://github.com/mingster/dotfiles/pull/802))
* `checks-local.sh` runs the same checks as the online build, and every brief now names it. ([#820](https://github.com/mingster/dotfiles/pull/820))
* Fleet computers refresh Orca's skills daily and upgrade Orca when idle. ([#837](https://github.com/mingster/dotfiles/pull/837), [#851](https://github.com/mingster/dotfiles/pull/851))
* The Grok command line tool became a worker option. Codex and ChatGPT were removed. ([#1098](https://github.com/mingster/dotfiles/pull/1098), [#1077](https://github.com/mingster/dotfiles/pull/1077))
* The usage check picks an Orca Claude account that has room. ([#1104](https://github.com/mingster/dotfiles/pull/1104))
* Verifiers check screens in a shared live check server and recheck only what changed. ([#1085](https://github.com/mingster/dotfiles/pull/1085), [#1102](https://github.com/mingster/dotfiles/pull/1102))
* The owner approval secret lives in the Keychain behind Touch ID. A separate credential folder is owned by root. ([#965](https://github.com/mingster/dotfiles/pull/965), [#941](https://github.com/mingster/dotfiles/pull/941))
* A `tune-agent-docs` skill cuts words from agent guides without changing a rule. ([#1040](https://github.com/mingster/dotfiles/pull/1040))
* Finished Orca cards move to Done on their own. ([#1013](https://github.com/mingster/dotfiles/pull/1013))

### Changed in how the team works

* `ship.sh` became the single merge path, and `lead-merge.sh` was removed. ([#868](https://github.com/mingster/dotfiles/pull/868))
* After two failed verdicts the team redesigns the change instead of patching a third time. ([#951](https://github.com/mingster/dotfiles/pull/951))
* The watcher got its own design and a full rebuild: it reruns red checks, then reworks, starts issues on other computers when this one is full, and logs each pass. ([#998](https://github.com/mingster/dotfiles/pull/998), [#1010](https://github.com/mingster/dotfiles/pull/1010), [#980](https://github.com/mingster/dotfiles/pull/980), [#1015](https://github.com/mingster/dotfiles/pull/1015))
* The brief check runs once, in the start script, and the fixed finish steps are added for the worker. ([#976](https://github.com/mingster/dotfiles/pull/976))
* Workers start on the least busy computer. ([#759](https://github.com/mingster/dotfiles/pull/759))
* Owner rules for the usage limit were written down: readings, ceilings, reserve and pacing. ([#1000](https://github.com/mingster/dotfiles/pull/1000))
* The cleanup tool checks the work folders of every computer, not only this one. ([#856](https://github.com/mingster/dotfiles/pull/856))

### Fixed

* Several false alarms in the command guard were removed, and it learned to read quoted text as data. ([#1012](https://github.com/mingster/dotfiles/pull/1012), [#1060](https://github.com/mingster/dotfiles/pull/1060), [#1134](https://github.com/mingster/dotfiles/pull/1134))
* Automatic checks now handle a pull request whose branch was rewritten. ([#1062](https://github.com/mingster/dotfiles/pull/1062), [#853](https://github.com/mingster/dotfiles/pull/853))
* Seats held by workers that were proven gone are freed. ([#1056](https://github.com/mingster/dotfiles/pull/1056), [#1068](https://github.com/mingster/dotfiles/pull/1068))
* A worker no longer leaves a terminal behind after it finishes. ([#894](https://github.com/mingster/dotfiles/pull/894), [#902](https://github.com/mingster/dotfiles/pull/902))
* Antigravity no longer gets stuck when a login shell sets the wrong SSH variables. ([#900](https://github.com/mingster/dotfiles/pull/900), [#913](https://github.com/mingster/dotfiles/pull/913))

## Week of 2026-11-02

### New

* A fleet watcher that keeps an eye on workers, pull requests and backups and opens one issue when a backup goes stale.
* One cleanup tool, `wrap-up.sh`, with a scheduled round every 10 minutes. It removes finished work folders and merged branches.
* `elon-startup.sh`, one script to run when the coordinator starts. ([#477](https://github.com/mingster/dotfiles/pull/477))
* A weekly update tool that brings in tested upstream skills.
* A fleet toolchain check that compares tool versions across computers, and an installer for the scheduled Orca jobs. ([#724](https://github.com/mingster/dotfiles/issues/724))
* A heavy job gate that makes browser tests and builds wait for a free slot.
* `ship.sh` for the merge step, and a brief check that stops a worker start when the brief is incomplete. ([#717](https://github.com/mingster/dotfiles/issues/717))
* Online checks now run the script tests for changed files.
* The Mac server installer covers the gaps found while setting up a new coordinator. ([#480](https://github.com/mingster/dotfiles/pull/480))

### Changed in how the team works

* Team roles and docs were moved into one template that every project adopts. Project folders keep five fixed files.
* The coordinator only hands out work, and workers own the issue.
* Host specific names moved to local files, and a guard checks that none reach this public repository.
* Grill questions are only required before work that touches money.

### Fixed

* Head checks wait for GitHub to show the pull request head and retry when a receipt is late.
* Heavy gate slots are reclaimed when their owner is gone and every process is proven stopped.
* The wrap up tool no longer closes a terminal that has recent output or an agent waiting on a person.
