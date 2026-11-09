# Lean Startup Agentic SDLC Specification (Next.js & TypeScript Optimized)

本文件定義專為極精實團隊設計的智慧代理人（Agentic）軟體開發生命週期。結合專案 SDLC 的交付流程與嚴格的 FinOps 護欄，徹底杜絕 Token 浪費與無效迴圈。

## 1. 核心開發編制與角色職責

全流程遵循專案 SDLC 與 `docs/agents/team.md`（2026-11-06 規範）。需求與新功能由 `architect-pm` 整合為單一設計文件並交由創辦人一次核准（涉及金流由 `secops-finops`、`architect-pm` 與 the coordinator 進行開工前 Grill；涉及新 UI 頁面由 `sales-marketing` 與 the coordinator 進行 Grill 並附上機截圖），工程派工與合併由 the coordinator 統籌，程式碼實作由 `fullstack-dev` 負責，品質由跨模型家族的 `qa-sdet`（及金流與權限議題的 `secops-finops`）獨立唯讀審查，每日 19:00 自動部署 Staging 並執行 pstack `swarm` 線上審查與完整回歸測試，最終正式環境發布（Production Go）由人類創辦人把關。

### 需求分析師兼產品架構師 (`architect-pm`)

* **核心目標**：將模糊的想法收斂為明確的技術規格與可執行任務清單。
* **交付產出**：
  * 單一功能設計文件（整合 `intent.md`、`spec.md` 與 units，一次核准）
  * GitHub issues from `to-tickets`（可獨立驗證的任務契約，單一內文須包含 `## Acceptance criteria`、`Requirement owner` 與 `Deleted` 三項欄位，以及對應 `## Test plan` 的測試案例）
* **規範**：規格書統一存放於專案定義的規格目錄（`docs/intent/<YYYY-MM-DD>-<slug>/`），架構決策寫入 `docs/adr/`，專有名詞收錄於 `CONTEXT.md`。

### 全端工程師 (`fullstack-dev`)

* **核心目標**：在獨立 Orca 子工作樹（`~/orca/workspaces/<project>/<lane>`）迅速實作並附上測試（修 Bug 先寫失敗測試再修復，僅在測試成本過高、高度依賴整合或目標不明確時例外；新功能、腳本與重構須附測試並於真實產物驗證 Prove It Works，不強制先紅燈，重構須證明行為不變），僅執行觸及的測試檔案（嚴禁自行跑完整回歸測試）。
* **交付產出**：
  * 符合規格的功能程式碼與測試案例
  * 獨立分支本地提交（新增 `changelog.d/<issue>-<slug>.md` 片段，嚴禁在 PR 直接修改 `CHANGELOG.md`）與 `worker_done` 報告（the coordinator 派遣 publication／merge worker 執行 `coordinator-publication.sh` 與 `lead-merge.sh`，須先通過 `head-checks.sh` 與跨家族 QA）
* **成功標準**：目標測試與 `head-checks.sh` 通過，且通過獨立 QA 與安全審查門禁。

## 2. 新創專用 FinOps 與防卡死護欄 (Infinite Loop Defuser)

### 質疑前提與三擊不中條款 (Attack the Premise & Three-Strike Rule)

* 當同一個檢查連續失敗第 2 次時，必須先執行 **Attack the Premise**：寫下前兩次失敗修法共同假設的前提並直接驗證，確認後才可進行第 3 次修正。
* 當 `fullstack-dev` 修改產品程式碼後的行為測試或型別檢查失敗達 3 次上限（缺套件、`prisma generate` 或 typegen 等環境工具錯誤不計入），AI 必須立刻中斷自動化任務（Hard Stop，由 `.claude/hooks/strikes.py` 強制執行），將當前報錯日誌與已排除的前提完整寫入 `active_run.md` 的 `[Blockers]` 區塊。
* 透過 `worker_done` 回報 the coordinator 或靜候創辦人介入，嚴禁盲目重試燃燒配額。

## 3. 單一動態執行聯絡簿 (`active_run.md`)

Agent 在執行多切片（multi-slice）複雜任務時，透過工作樹根目錄中的輕量 `active_run.md`（Git 忽略）維護即時狀態。此檔案僅於修改程式碼前建立一次，並於受阻（Blocked）或交接（Handoff）時更新，任務完成並合併後即可清除。

```markdown
# Active Run Session

## 當前時間與進度
- Session ID: run_20261107_01
- 執行 Agent: fullstack-dev
- 當前目標: 實作金流結帳錯誤頁面與單元測試

## 允許修改檔案 (Whitelist)
- `src/app/checkout/error/page.tsx`
- `src/components/payment/FeedbackWidget.tsx`

## 推進狀態日誌 (Progress Log)
- Step 1: 完成頁面靜態 RWD 刻版
- Step 2: 整合狀態碼讀取與單元測試

## 阻礙與報錯 (Blockers: Strike Count 2 of 3)
- 錯誤訊息: Type string or null is not assignable to type string.
- 已嘗試解法:
  1. 嘗試使用空值消除，但引發上游 Props 衝突
  2. 嘗試使用斷言，導致測試失敗
- 備註: 已觸發第 2 次失敗，須先驗證上游型別前提；若第 3 次行為驗證失敗將自動觸發三擊不中條款停止運行
```

## 4. 安全與合規護欄 (Security Guardrails)

1. **環境變數零信任 (Zero-Env Disclosure)**：Agent 在任何時候更新或建立 Markdown 文件或終端輸出時，嚴禁將 `.env` 中的真實金鑰、密碼或 Token 寫入檔案或螢幕。
2. **預留占位符 (Placeholders)**：所有涉及金流密鑰或資料庫連線字串的地方，一律使用 `[Omitted/Configured via Env]` 替代，並使用 `.claude/bin/env-peek.py` 做遮罩檢查。
3. **人類審查與合併門禁**：AI 工程師僅在專屬工作樹本地提交；the coordinator 派遣 publication 與 merge worker 執行發布與 `lead-merge.sh`。角色定義變更須附帶 `Owner-approved:` commit trailer，正式環境上線由人類創辦人逐次核准。

## 5. 對話脈絡與 Token 節省守則 (Context Hygiene & Token Conservation)

1. **一票一會話 (One Unit, One Session)**：
   當 `fullstack-dev` 完成單一票券本地提交、驗證並送出 `worker_done` 後，該次 Worker 即告結束並由 `worker-pane-close.sh --release` 與 `wrap-up.sh` 回收。嚴禁在同一個會話中直接開啟下一項無關任務。
2. **多輪長任務的 Compaction 容錯 (In-Task Compaction Resilience)**：
   若單一多切片任務執行輪數較多（或達到 80% Context / 120 輪預算提醒），可透過 `active_run.md` 與 `handoff` 技能保存狀態，確保重啟或 Compaction 後第一輪即可無痛接續。
3. **Orca 隔離派工 (Supervised Orca Workers)**：
   大量檔案調查、實作與獨立審查皆由 the coordinator 透過 Orca Orchestration（`orca orchestration worker-start`，經由 `usage-gate.py` 與 `heavy-gate.sh` 管控）派發給獨立工作樹的 Worker 執行，嚴禁使用 Claude 內建 subagents。主會話僅讀取簡短統計摘要（如 `git diff --stat` 與測試計數）。
4. **探勘沙盒 (Spike Isolation)**：
   對於程式碼即可回答的可行性問題，在 `.scratch/` 或拋棄式分支進行輕量驗證並將結果貼入規格；若需建立 2 至 3 個競爭原型（Exhaust the Design Space），須先由 the coordinator 以中文向創辦人報價並取得明確核准。
