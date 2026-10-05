# Lean Startup Agentic SDLC Specification (Next.js & TypeScript Optimized)

本文件定義專為極精實團隊設計的智慧代理人（Agentic）軟體開發生命週期。結合專案 SDLC 的六階段交付流程與嚴格的 FinOps 護欄，徹底杜絕 Token 浪費與無效迴圈。

## 1. 核心開發編制與角色職責

全流程遵循專案 SDLC 規範。需求由 `architect-pm` 分析，工程排程由 `lead` (Tech Lead) 統籌，程式碼實作由 `fullstack-dev` 負責，品質由 QA 與安全團隊獨立審查，上線由 `release-manager` 推進，最終發布門禁由人類創辦人把關。

### 需求分析師兼產品架構師 (`architect-pm`)

* **核心目標**：將模糊的想法收斂為明確的技術規格與任務清單。
* **交付產出**：
  * 專案規格文件 (`intent.md` 與 `spec.md`)
  * `tickets.md` (可獨立驗證的原子級任務契約)
* **規範**：規格書統一存放於專案定義的規格目錄，架構決策寫入 ADR，專有名詞收錄於 `CONTEXT.md`。

### 全端工程師 (`fullstack-dev`)

* **核心目標**：以 TDD 模式迅速實作功能，維護程式碼品質與單元測試。
* **交付產出**：
  * 符合規格的功能程式碼與測試案例
  * 獨立分支與 PR (包含 `CHANGELOG.md` 更新與設計說明)
* **成功標準**：本地測試 100% 通過，且通過 QA 與安全審查門禁。

## 2. 新創專用 FinOps 與防卡死護欄 (Infinite Loop Defuser)

### 三擊不中條款 (Three-Strike Rule)

* 當 `fullstack-dev` 在修改同一個 Bug、型別錯誤或測試失敗時，嘗試修正次數上限為 3 次。
* 若第 3 次執行驗證依然報錯，AI 必須立刻中斷自動化任務（Hard Stop），將當前報錯日誌與嘗試過的解法完整寫入 `active_run.md` 的 `[Blockers]` 區塊。
* 靜候人類創辦人介入排解，嚴禁盲目重試燃燒 Token。

## 3. 單一動態執行聯絡簿 (`active_run.md`)

Agent 在執行多輪複雜任務時，透過工作目錄中的輕量 `active_run.md` 維護即時狀態。此檔案為執行期間的動態快取，任務完成並開立 PR 後即可清除。

```markdown
# Active Run Session

## 當前時間與進度
- Session ID: run_20261005_01
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
- 備註: 再失敗一次將自動觸發三擊不中條款，停止運行
```

## 4. 安全與合規護欄 (Security Guardrails)

1. **環境變數零信任 (Zero-Env Disclosure)**：Agent 在任何時候更新或建立 Markdown 文件時，嚴禁將 `.env` 中的真實金鑰、密碼或 Token 寫入檔案。
2. **預留占位符 (Placeholders)**：所有涉及金流密鑰或資料庫連線字串的地方，一律使用 `[Omitted/Configured via Env]` 替代。
3. **人類審查與合併門禁**：AI 代理人僅在專屬分支開發，合併由 Tech Lead 依審查結果執行，正式上線與發布門禁由人類創辦人把關。

## 5. 對話脈絡與 Token 節省守則 (Context Hygiene & Token Conservation)

1. **任務即會話生命週期 (One Ticket, One Session)**：
   當 `fullstack-dev` 完成任務並開立 PR 後，該次任務的 Agent 執行即告結束。嚴禁在同一個會話中直接開啟下一項無關任務。下一項任務應由 Tech Lead 或創辦人啟動全新乾淨的會話或新子代理人，確保上下文 Token 從零開始，徹底避免前案歷史殘留造成的 Token 膨脹。
2. **多輪長任務的 Compaction 容錯 (In-Task Compaction Resilience)**：
   若單一任務執行輪數較多（例如超過 15 到 20 輪），創辦人可在對話中執行 `/compact`。由於 Agent 已即時維護 `active_run.md`，Compaction 後 Agent 能在第一輪重讀 `active_run.md` 恢復狀態，無痛接續工作。
3. **側枝隔離 (Side Subagent Offloading)**：
   大量檔案讀取、日誌掃描與探索性調查，必須交由隔離的子代理人執行，主會話僅接收簡短統計摘要（例如 `git diff --stat` 與測試結果），避免主對話脈絡被大量工具輸出污染。
4. **探勘沙盒 (Spike Isolation)**：
   對於高不確定性的 Bug 修正或實驗性重構，應在獨立分支或 Fork 的會話中嘗試。若嘗試失敗直接捨棄該分支與會話，不將無效試錯的長堆疊殘留在主要交付會話中。
