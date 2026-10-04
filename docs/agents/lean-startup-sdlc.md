# Lean Startup Agentic SDLC Specification (Next.js & TypeScript Optimized)

本文件定義專為新創、一人公司（Solopreneur）與極精實團隊設計的智慧代理人（Agentic）軟體開發生命週期。透過雙代理人極簡編制與嚴格的 FinOps 護欄，在極大化自動化生產力的同時，徹底杜絕 Token 浪費與無效死迴圈。

---

## 🧱 1. 雙代理人極簡編制 (The Dual-Agent Pod)

新創階段拒絕疊床架屋。全流程由兩名頂級虛擬專家協同，並由人類創辦人扮演最高審查節點。

### 🧑‍💻 Agent A: Product-Architect (產品架構師 / `architect-pm`)

* **核心目標**：將人類創辦人模糊、高頻變動的想法，收斂為乾淨、無歧義的技術規格與任務清單。
* **研究領域**：Next.js App Router 最佳實踐、TypeScript 嚴格型別架構、API 邊界設計。
* **交付產出**：
  * `SPEC.md` / `product_backlog.md` (Living Specification / 動態需求規格)
  * `ARCHITECTURE.md` (資料庫 Schema、API 路由與元件樹設計)
* **成功標準**：產出的任務清單必須是「不可再拆解的原子級任務 (Atomic Tasks)」，且程式碼開發員無需再次提問即可實作。

### 🛠️ Agent B: Full-Stack Builder (全端開發者 / `fullstack-dev`)

* **核心目標**：以極高速度實作功能，並維持 Next.js 專案的現代化程式碼品質與單元測試覆蓋。
* **研究領域**：React Server Components (RSC)、TypeScript 效能優化、自動化測試（Bun test / Playwright / Vitest）。
* **交付產出**：
  * 符合 Lint 與 Type Check 的功能程式碼
  * 伴隨功能的單元或整合測試（Test-driven 導向）
* **成功標準**：本地測試 100% 通過，且程式碼未引入任何未處理的 side effects 或全域型別阻斷。

---

## 🔄 2. 精實開發工作流 (Lean Agentic Workflow)

核心工作流遵循「發現 -> 設計 -> 執行 -> 測試 -> 審查」的極速閉環，每一步皆以狀態檔案進行脈絡同步。

---

## 🛑 3. 新創專用 FinOps 與防卡死護欄 (Infinite Loop Defuser)

為了保護新創團隊微薄的 API 額度，系統內建最高級別的阻斷機制。

### ⚠️ 三擊不中條款 (Three-Strike Rule)
* 當 Full-Stack Builder 在修改同一個 Bug、型別錯誤（Type Error）或測試失敗時，**嘗試修正次數上限為 3 次**。
* 若第 3 次執行本地防護驗證依然報錯，**AI 必須立刻中斷自動化任務（Hard Stop）**，將當前報錯日誌、嘗試過的解法完整寫入 `active_run.md`（或 `progress.md`）中的 `[Blockers]` 區塊。
* 拋出異常提示，靜候人類創辦人（Human-in-the-loop）介入排解。嚴禁盲目重試燃燒 Token。

### 💸 Token 熔斷器 (Cost Gate: 3 Turns)
* 單次自動化任務執行的對話或工具呼叫輪數達到臨界值（**單次任務上限 3 Turns**）時，必須強制進行進度封存（Snapshot 至 `active_run.md`），並向人類創辦人回報確認方可繼續。
* 防止 Agent 在未向人類匯報前自發發散執行，嚴控 Token 支出。

---

## 💾 4. 持久化記憶與動態快取層結構 (State Artifacts)

Agent 團隊必須透過以下輕量 Markdown 檔案維護上下文，這也是防止 Agent 迷失的「動態快取」。

### 📋 檔案一：`product_backlog.md` (產品待辦與規格書)
```markdown
# Product Backlog & Specs

## 🎯 當前里程碑: MVP 發布
- [x] 使用者認證模組 (Next-Auth / Better Auth 整合)
- [/] 核心業務儀表板 (進行中)
- [ ] 統一支付金流串接 (待處理)

## 📝 活體規格說明 (Living Specs)
### 支付模組規格
1. 必須串接指定本地金流。
2. 提供一鍵刷卡與行動支付。
3. 錯誤處理：當金流 API 回傳失敗時，必須導向專屬 `/checkout/error` 頁面，且不得洩漏底層金流密鑰。
```

### ⚡ 檔案二：`active_run.md` (當前執行聯絡簿)
```markdown
# Active Run Session

## 📅 當前時間與進度
- **Session ID**: run_20261004_01
- **執行 Agent**: Full-Stack Builder
- **當前目標**: 實作支付失敗的 `/checkout/error` 頁面與 UI 測試。

## 🛠️ 已變動檔案 (Git Staged/Modified)
- `src/app/checkout/error/page.tsx` (Created)
- `src/components/payment/FeedbackWidget.tsx` (Modified)

## 📌 推進狀態日誌 (Progress Log)
- [Step 1] 完成頁面靜態 RWD 刻版。
- [Step 2] 整合狀態碼讀取，可動態顯示金流拒絕原因。

## ❌ 阻礙與報錯 (Blockers - Strike Count: 2)
- **錯誤訊息**: `Type 'string | null' is not assignable to type 'string'.` 在 `page.tsx` 第 24 行。
- **已嘗試解法**: 
  1. 嘗試使用 `?? ''` 進行空值消除，但引發上游組件 Props 衝突。
  2. 嘗試使用絕對斷言 `!`，導致測試案例崩潰。
- **備註**: 再失敗一次將自動觸發「三擊不中條款」，停止運行。
```

---

## 🛡️ 5. 安全與合規護欄 (Security Guardrails)

1. **環境變數零信任 (Zero-Env Disclosure)**：Agent 在任何時候更新或建立 `SPEC.md`、`ARCHITECTURE.md`、`active_run.md` 或任何文件時，嚴禁將 `.env` 中的真實金鑰、密碼、Token 寫入任何 Markdown 檔案。
2. **預留占位符 (Placeholders)**：所有涉及金流密鑰（如 Stripe / Line Pay Secret）、資料庫連線字串的地方，一律使用 `[Omitted/Configured via Env]` 替代。
3. **人類合併制 (Human Merger Only)**：AI 代理人僅擁有本地分支（Branch）開發權限，合併與上線門禁由人類創辦人牢牢把關。
