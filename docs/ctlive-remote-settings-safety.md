# CTLive 遠端設定：可調範圍與防呆設計

> 目標：網頁端可以設定 App 的所有推流參數，攝影師完全不必碰手機。
> 前提：**不能因為導播改了一個設定就把正在跑的直播打斷。**
>
> 本文的分級不是憑經驗猜的，是從 Moblin 自己的 UI 閘門（`.disabled(...)`）反推出來的 ——
> 上游作者已經替每個設定判斷過「改了會不會斷流」，直接沿用比重新發明可靠。
>
> 撰寫日期：2026-08-13。

---

## 1. 核心原則：**下發 = 存檔，套用 = 另一件事**

最重要的一個決定：**收到設定永遠先存檔並持久化，套用與否由 App 依當下狀態決定。**

```
後端下發設定
     │
     ▼
  ┌─────────┐   永遠執行
  │  存檔    │ ──────────────► 寫入設定 + 立刻落磁碟
  └────┬────┘
       │
       ▼
  ┌─────────────────┐
  │ 這個設定的等級   │
  │ 允許現在套用嗎？ │
  └────┬───────┬────┘
    是 │       │ 否
       ▼       ▼
   立即套用   標記為「待套用」
   + 提示     + 回報後端「已存檔，停播後生效」
   攝影師     + 面板顯示待套用項目
                    │
                    ▼
              停播時自動套用
```

這樣做的好處：**網頁端永遠可以改任何設定，不會有「這個欄位在直播中不能編輯」的爛體驗**，而斷流風險由 App 端把關。

---

## 2. 分級表（來源：Moblin 自身的 UI 閘門）

### 🟢 A 級 — 直播中可改，立即生效

| 設定 | 備註 |
|---|---|
| 位元率 / bitrate preset | `media.updateVideoStreamBitrate`，本來就是給 IRL 路上調的 |
| **SRT 連線優先權** | SRT 設定裡**唯一**沒有 live 閘門的，多網路聚合切換用 |
| 場景切換 | |
| 麥克風切換 | |
| 變焦 / 變焦預設 | |
| 手電筒、靜音 | |
| 濾鏡 | |
| 直播開關、錄影開關 | 已實作且冪等 |

### 🔴 B 級 — 直播中禁止套用（會觸發 `reloadStream()` → 斷流）

依據 `.disabled(stream.enabled && model.isLive)`：

| 分類 | 設定 |
|---|---|
| 影像 | Codec、Profile、Rate control、B-frames、Adaptive resolution、Timecodes / NTP pool |
| SRT | Latency、Adaptive bitrate、Max bandwidth follows input、Overhead bandwidth、Big packets、DNS lookup strategy、Implementation |
| RTMP | Adaptive bitrate |
| RIST | Adaptive bitrate、Bonding |
| WHIP | Bearer token、HTTP transport |
| 音訊 | Codec、位元率 |

檔案：`StreamVideoSettingsView.swift`、`StreamSrtSettingsView.swift`、`StreamRtmpSettingsView.swift`、`StreamRistSettingsView.swift`、`StreamWhipSettingsView.swift`、`StreamAudioSettingsView.swift`

### 🔴🔴 C 級 — 直播中**或**錄影中都禁止（同時影響編碼器與錄影檔）

依據 `.disabled(stream.enabled && (model.isLive || model.isRecording))`：

| 設定 | 為什麼更嚴格 |
|---|---|
| **解析度** | 錄影檔中途換解析度會壞檔 |
| **FPS** | 同上 |
| **推流 URL / streamKey** | `StreamUrlSettingsView` 明確 `disabled: model.isLive \|\| model.isRecording` |
| 直向 / 橫向 | 會 `setCurrentStream` + `reloadStream` |
| 多目標推流目的地 | |
| **切換 / 新增 / 刪除 stream 設定** | `StreamsSettingsView` 整個列表在直播或錄影中鎖住 |

### 🟠 D 級 — 錄影中禁止（直播中可以改）

錄影專屬：Video codec、Video bitrate、錄影路徑、錄影音訊設定。

---

## 3. 防呆設計（逐項）

### 3.1 App 端自己擋，不依賴後端

後端已經證明它的 `isLive` 判斷會出錯（`startStatus` 缺欄位導致 status 從未送達，`isLive` 一直未知且 fail-open）。

**規則：每個會改設定的 request，App 在套用前重新檢查當下的 `isLive` / `isRecording`。** 兩邊都擋，任一邊漏掉都不會斷流。

### 3.2 不能靜默丟棄，要明確回報

被擋下的設定必須回一個明確的 response，而不是回 ok 或什麼都不回：

```json
{"response":{"id":7,"result":{"ok":{}},"data":{"applySettings":{
  "applied":["bitrate","srtConnectionPriorities"],
  "deferred":[{"key":"resolution","reason":"live"},
              {"key":"streamUrl","reason":"live"}]
}}}}
```

儀表板要能顯示「**3 項設定已儲存，將於停播後生效**」。導播看到的必須是真相，不是「已套用」的假象。

### 3.3 停播時自動套用待處理設定

`stopStream()` 完成後檢查 pending 清單 → 套用 → 通知後端 → 提示攝影師「已套用導播的 3 項設定」。

這是「攝影師不必碰手機」的關鍵一環：導播賽前改的設定，攝影師停播一次就自動生效，不用進設定頁。

### 3.4 想立刻換 URL 怎麼辦：明確的「停播 → 換 → 開播」

C 級設定若導播真的要立刻生效，唯一安全的路徑是**有意識地斷流**。做成一個獨立指令：

```json
{"request":{"data":{"switchStreamProfile":{"id":"<uuid>","restartStream":true}}}}
```

App 收到後：停播 → 套用 → 重新開播，全程提示攝影師。**儀表板上這顆按鈕必須明講「會中斷直播約數秒」並要求導播二次確認** —— 二次確認放在導播端，攝影師端不確認（否則就違背了不必碰手機的目標）。

`restartStream: false`（預設）則只存檔。

### 3.5 競態：指令抵達時狀態正在變化

導播按下設定的瞬間攝影師可能正好開播。**以 App 套用當下的狀態為準**，並在 response 裡帶回當時實際的 `isLive` / `isRecording`，讓儀表板能解釋為什麼被延後。

### 3.6 順序保證

後端可能連續送 `setStreamProfiles` 再送 `setActiveStreamProfile`。App 端依序處理同一條 WebSocket 的訊息，先存後套；若 active 指向的 id 不存在 → 回錯誤，不要套用到錯的 profile。

### 3.7 伺服器為準的刪除要保守

「清單中沒有的本地設定請刪除」很危險：一次下發失誤就會把攝影師本地的備援設定清光。

**建議：只刪除「曾經由伺服器建立」的 profile（記 `origin: server` 標記），本地手動建立的一律保留。** 攝影師自己建的備援設定是他的保命索，不該被遠端清掉。

### 3.8 正在使用中的 profile 不可刪

若下發的清單刪掉了當前正在推流的 profile：直播中 → 拒絕刪除，回報衝突；非直播 → 允許但要有 fallback。

### 3.9 streamKey 保護

- **不可進 log**（我目前的解碼失敗 log 會印訊息原文，實作 profiles 前必須先加遮罩）
- UI 上比照現有 `sensitive: true` 遮罩
- 建議存 Keychain

### 3.10 攝影師的最終控制權

面板上的「切斷遠端控制」紅色按鈕保留。任何時候攝影師都能收回控制權，這是安全閥不是備案。

---

## 4. 建議實作順序

| 階段 | 內容 |
|---|---|
| 1 | 分級表寫進程式碼（每個 request 標 A/B/C/D），`applySettings` 的存檔 + 延後 + 回報骨架 |
| 2 | `setStreamProfiles` upsert / `origin: server` 標記 / Keychain / streamKey log 遮罩 |
| 3 | 停播自動套用 pending、面板顯示待套用清單 |
| 4 | `switchStreamProfile(restartStream: true)` 的有意識斷流路徑 |

---

## 5. 待確認

- 伺服器下發的 profile 要不要包含**畫質參數**（解析度/fps/codec/bitrate）？包含的話攝影師本地調好的設定會被覆蓋。建議：**伺服器只管 URL / key / 名稱 / 啟用**，畫質留給攝影師；若要遠端管畫質，做成獨立的 `setVideoSettings` 指令，走同一套分級與延後機制
- 待套用設定的保留期限：賽後沒停播就一直留著嗎？建議顯示但不過期
