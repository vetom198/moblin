# CTLive 遠端導播控制 — 架構設計

> 目標：管理者在 CTLive 網頁儀表板上，控制現場 iPhone（CTLiveGo / Moblin fork）的推流 URL、
> 開播/停播、錄影開關、相機與麥克風參數；iPhone 端顯示提示讓攝影師知道；
> 同時把 Moblink / 網路聚合等狀態回傳。
>
> 本文件是 **iOS 端與後端的共同契約**。§6 之後是給 CTLive 後端（ctyweb）實作用的。
>
> 撰寫日期：2026-08-12。對應 App：CTLiveGo（Moblin fork，`remoteControlApiVersion = "0.1"`）。

---

## 1. 結論：不要另外發明控制通道

Moblin 內建一套完整的 **remote control 協定**，本來就是為了「導播在家、攝影師在外」這個場景設計的。
CTLive 後端只要扮演協定裡的 **assistant**（WebSocket 伺服器），iPhone 用現成的 **streamer** 模式連出去即可。

為什麼這是對的選擇：

| 理由 | 說明 |
|---|---|
| **穿透 NAT** | iPhone 主動往外連 `wss://`，行動網路 CGNAT / 防火牆完全不是問題。反向連線做不到 |
| **大部分功能是 0 行 iOS 程式碼** | 開播、停播、錄影、場景、麥克風、bitrate、zoom、手電筒、濾鏡、SRT 連線優先權已全部實作 |
| **狀態回傳也已經有了** | 含 **moblink**、srtla、bitrate、uptime、電量、機身溫度、GPS、RTMP server、DJI 裝置 |
| **附贈預覽畫面** | `startPreview` 之後 iPhone 會週期送 JPEG，儀表板可以直接看到攝影師的畫面 |
| **加密與認證現成** | challenge/salt + SHA256 雙輪雜湊，密碼不過線 |

自建控制通道要重做以上每一項，而且會跟既有的 remote control 打架（兩套都在改同一個 model 狀態）。

### 資料流

```
                    ┌──────────────────────────────────────┐
                    │  CTLive 後端 live.ctyeh.com          │
  管理者瀏覽器 ────► │                                      │
   (儀表板)         │  ┌────────────────┐  ┌────────────┐ │
                    │  │ device-data    │  │ remote     │ │
                    │  │ (已完成)       │  │ control    │ │
                    │  │ HTTP POST 上行 │  │ assistant  │ │
                    │  └───────▲────────┘  │ WebSocket  │ │
                    │          │           │ 雙向       │ │
                    └──────────┼───────────┴─────▲──────┘
                               │                 │
                    每 1-10 秒 │                 │ 常駐連線
                    位置/速度/ │                 │ 指令下行 + 狀態/預覽上行
                    距離/時間  │                 │
                    ┌──────────┴─────────────────┴──────┐
                    │  iPhone — CTLiveGo                │
                    │  CtLiveTracker    RemoteControlStreamer │
                    └───────────────────────────────────┘
```

兩條通道刻意分開：數據上傳是無狀態的 last-write-wins 快照（斷線可丟），控制通道是有狀態的長連線。
混在一起會讓「斷網重連後不要補傳舊點」這條規則變得很難維持。

---

## 2. 現成可用，iOS 端不用改

以下 `RemoteControlRequest` 已經實作完畢（`Moblin/RemoteControl/RemoteControl.swift`）：

| Request | 效果 | 對應需求 |
|---|---|---|
| `setStream(on:)` | 開始 / 停止直播 | ✅ 實況開關 |
| `setRecord(on:)` | 開始 / 停止錄影 | ✅ 錄影開關 |
| `setMic(id:)` | 切換麥克風（內建 / 外接 / 藍牙） | ✅ 麥克風參數（部分） |
| `setZoom(x:)` / `setZoomPreset(id:)` | 變焦 | ✅ 相機參數（部分） |
| `setTorch(on:)` / `setMute(on:)` | 手電筒 / 靜音 | |
| `setScene(id:)` | 切換場景（連帶切前後鏡頭、外接相機） | ✅ 相機參數（部分） |
| `setBitratePreset(id:)` | 切 bitrate | |
| `setSrtConnectionPriority(...)` | SRT 多網路優先權 | ✅ 網路聚合控制 |
| `setFilter(filter:on:)` | 濾鏡 | |
| `startPreview` / `stopPreview` | 開關預覽串流 | 儀表板看畫面 |
| `startStatus(interval:filter:)` | 要求週期回報狀態 | ✅ 狀態回傳 |
| `getSettings` | 取得手機上的場景 / mic / bitrate preset / SRT 清單 | 儀表板要先拿這個才知道有哪些選項 |

回報的狀態（`RemoteControlStatusTopRight` / `TopLeft` / `General`）已包含：

```
general:  batteryCharging, batteryLevel, flame(機身溫度), wiFiSsid, isLive, isRecording, isMuted
topLeft:  stream, camera, mic, zoom, obs, events, chat, viewers
topRight: audioLevel, rtmpServer, remoteControl, gameController, bitrate, uptime,
          location, srtla, srtlaRtts, recording, replay, browserWidgets,
          moblink ←──── 網路聚合狀態就在這裡, djiDevices, systemMonitor
```

`moblink` 欄位內容是 `moblinkStreamerStatus()` 產生的字串（relay 狀態 + 已連線 relay 數）加一個 `ok: Bool`。

---

## 3. iOS 端需要新增的（依重要性排序）

### 3.1 推流 URL 控制 — 協定目前沒有

兩個做法，建議 **A 為主、B 為輔**：

**A. `setStreamId(id: UUID)` — 切換手機上已設定好的 stream（推薦）**

- 攝影師事先在手機上建好幾組 stream（主線 / 備援 / 測試）
- 網頁只送 UUID，**推流 URL 和 stream key 完全不過線**
- 手機端邏輯已存在：`setCurrentStream(streamId:)` → `reloadStream()` → `sceneUpdated()`，
  就是 `QuickButtonStreamSwitcherView` 在做的事（切換後會自動開播）
- `getSettings` 回應需要多帶 stream 清單（目前只有 scenes / mics / bitratePresets / srt / gimbalPresets）

**B. `setStreamUrl(url: String, key: String?)` — 直接推任意 URL**

- 活動當天臨時換 ingest 用，不必請攝影師手動打字
- 代價：stream key 會經過後端。連線是 wss + TLS，但後端 log 要確保不記錄
- 建議加一個手機端開關「允許遠端設定推流網址」，預設關閉

實作位置：
- `Moblin/RemoteControl/RemoteControl.swift` — `RemoteControlRequest` 加 case
- `RemoteControlStreamer.swift` — `handleRequest` 加 case + delegate 方法
- `Moblin/Various/Model/ModelRemoteControl.swift` — 實作 delegate

### 3.2 提示攝影師 — 協定目前沒有

新增 `showMessage(title: String, subTitle: String?, severity: RemoteControlMessageSeverity)`：

- `severity` = `info` / `warning` / `error`，對應現成的 `makeToast` / `makeWarningToast` / `makeErrorToast`
- 帶震動（`makeToast(vibrate: true)`），戶外看不到螢幕也感覺得到
- **另外**：每一個遠端指令都自動吐一個 toast，不需要管理者手動送。
  例如收到 `setStream(on: true)` → 「導播已開始直播」。這比純被動的訊息實用得多，
  攝影師不會發生「咦怎麼突然在直播了」

建議實作成一個統一的 `remoteControlAnnounce(_ text: String)`，在每個 delegate 方法開頭呼叫。

### 3.3 相機 / 麥克風參數

model 層的函式都在，只差協定 case：

| 新 Request | 對應 model 函式 | 檔案 |
|---|---|---|
| `setExposureBias(bias: Float)` | `setExposureBias(bias:)` | ModelCamera.swift:882 |
| `setManualFocus(lensPosition: Float)` | `setManualFocus(lensPosition:)` | ModelCamera.swift:138 |
| `setWhiteBalance(...)` | 參考 `setWhiteBalanceAfterCameraAttach` | ModelCamera.swift:368 |
| `setStreamFps(fps: Int)` | `setStreamFps(fps:)` | ModelStream.swift:774 |
| `setStreamResolution(...)` | `setStreamResolution()` | ModelStream.swift:366 |
| `setBitrate(bitrate: UInt32)` | `setBitrate(bitrate:)` | ModelStream.swift:791 |
| `setMicGain(...)` | 見 `setupInputGainObserver` 附近 | Model.swift |

注意：解析度 / fps 的變更會 `reloadStream()`，**直播中改會斷流**。
建議這幾項在儀表板上標成「直播中不可改」，或後端在 `isLive` 時擋掉。

### 3.4 裝置身分對應（必要）

remote control 的 `streamerId` 是另一組 UUID（`@AppStorage("remoteControlStreamerId")`），
跟 CTLive 的 `IPHONE-92C1AD44` **不是同一個**。儀表板必須把「正在上傳數據的裝置」
和「可以控制的裝置」對起來，否則管理者不知道自己在控哪一台。

建議做法（同時解決認證問題）：

1. 配對（redeem）成功時，後端額外回一個 **`control_token`**（每裝置一組隨機字串）
2. App 存進 Keychain，並把 remote control streamer 設定成：
   - URL：`wss://live.ctyeh.com/ws/live/remote-control/<device_id>/`
   - password：`control_token`
3. 後端從 URL path 就知道是哪個 device，不需要額外的 identify 欄位

這樣 CTLive 使用者完全不需要手動設定 remote control（現行 Moblin 要手動貼 URL 和密碼）。
App 端加一個開關「允許 CTLive 遠端控制」，開啟時自動用上面的參數啟動 streamer。

---

## 4. 建議分期

| 階段 | 內容 | iOS 工作量 |
|---|---|---|
| **P1** | 後端實作 assistant + 儀表板；App 加「允許 CTLive 遠端控制」開關與自動設定；開播/停播、錄影、狀態回傳、每個遠端動作自動 toast | 小（設定 + 自動連線 + toast） |
| **P2** | 推流切換（方案 A）、`getSettings` 帶 stream 清單、`showMessage` | 中 |
| **P3** | 預覽畫面、相機/麥克風細部參數、方案 B 任意 URL | 中 |

P1 的價值密度最高：後端寫完就能開播停播 + 看到全部狀態，iOS 幾乎不用動。

---

## 5. 安全性注意事項

- **控制通道等同可以操作攝影機**，`control_token` 必須是高熵隨機值，且只在 redeem 回應裡出現一次
- 後端要驗證「發指令的管理者」對這個 device 有權限（owner 或賽事主辦方），不能只驗 device 側
- App 端建議保留一顆「切斷遠端控制」的 quick button，攝影師隨時可以奪回控制權
- 方案 B（任意推流 URL）預設關閉，開啟時 App 顯示明顯警告

---

# 給 CTLive 後端的實作規格

> 以下是 assistant 端（Python）要實作的協定細節。所有形狀都已用 Swift 實測驗證。

## 6. 連線與握手

WebSocket endpoint（建議）：`wss://live.ctyeh.com/ws/live/remote-control/<device_id>/`

握手順序（**assistant 先講話**）：

```
assistant → streamer   {"hello":{"authentication":{"challenge":"<隨機>","salt":"<隨機>"},"apiVersion":"0.1"}}
streamer  → assistant  {"identify":{"authentication":"<hash>","streamerId":"<uuid字串>"}}
assistant → streamer   {"identified":{"result":{"ok":{}}}}
```

密碼驗證失敗時回 `{"identified":{"result":{"wrongPassword":{}}}}`，App 會顯示 "Wrong password"。

### 6.1 密碼雜湊（已驗證與 Swift 相符）

```python
import hashlib, base64

def remote_control_hash_password(challenge: str, salt: str, password: str) -> str:
    d = hashlib.sha256((password + salt).encode()).digest()
    d = hashlib.sha256((base64.b64encode(d).decode() + challenge).encode()).digest()
    return base64.b64encode(d).decode()
```

**測試向量**（Swift 與 Python 輸出一致，實測過）：

```
challenge = "challenge123"
salt      = "salt456"
password  = "hunter2"
→ "jTaxuy+FWqYi301wAiZCBToIwXt7IvSqOrsgkIH5nCc="
```

challenge 和 salt 每次連線都要重新隨機產生（防重放）。

## 7. 訊息格式

Swift 的 `Codable` enum 帶關聯值時，JSON 形狀是 **`{"caseName": {關聯值...}}`**；
沒有關聯值的 case 是 **`{"caseName": {}}`**（不是字串，也不是 null）。以下都是實測輸出：

```jsonc
// assistant → streamer
{"hello":{"authentication":{"challenge":"C","salt":"S"},"apiVersion":"0.1"}}
{"identified":{"result":{"ok":{}}}}
{"request":{"data":{"setStream":{"on":true}},"id":1}}
{"request":{"data":{"getStatus":{}},"id":2}}
{"request":{"data":{"setZoom":{"x":2}},"id":3}}
{"pong":{}}

// streamer → assistant
{"identify":{"authentication":"<hash>","streamerId":"<uuid>"}}
{"ping":{}}
{"response":{"id":1,"result":{"ok":{}},"data":null}}
{"event":{"data":{"status":{...}}}}
{"event":{"data":{"state":{"data":{...}}}}}
{"preview":{"preview":"<base64 JPEG>"}}
```

要點：

- **物件內欄位順序不固定**（Swift 沒有保證），不要依賴順序
- `request.id` 是 assistant 給的遞增整數，streamer 會用同一個 id 回 `response`
- 沒有結果的指令回 `{"response":{"id":N,"result":{"ok":{}},"data":null}}`
- streamer 每 30 秒送 `{"ping":{}}`，**assistant 必須回 `{"pong":{}}`**。
  沒回的話 streamer 會判定連線死掉並重連
- 二進位 frame 不使用；預覽 JPEG 是走 JSON 的 base64（Swift `Data` 的 Codable 預設編碼）
- 只有 Twitch access token 有額外 AES-GCM 加密，本專案用不到

## 8. 開場流程（assistant 端建議）

```
1. hello / identify / identified
2. request getSettings   → 拿到 scenes / mics / bitratePresets / srt 清單，儀表板才知道有哪些選項
3. request getStatus     → 拿一次完整狀態
4. request startStatus(interval: 1, filter: {"topRight": true})
                         → 之後 streamer 會週期送 {"event":{"data":{"status":{...}}}}
5. 之後依管理者操作送 setStream / setRecord / ...
```

`startStatus` 的 `interval` 單位是秒。`filter.topRight` 為 true 時只送 topRight（省流量）。

## 9. 需要 CTLive 後端配合新增的 API

1. **redeem 回應多帶 `control_token`**（每裝置一組隨機字串，用於 remote control 密碼）
   - 現有 redeem 回應：`device_id`, `device_internal_id`, `owner_username`, `owner_id`, `bound_at`, `created`
   - 新增：`control_token`（String）、`control_url`（String，wss URL）
   - App 端會把這兩個存起來自動設定 remote control
2. **check 回應也帶同樣兩個欄位**（App 重裝或換機後要能拿回來）
3. **WebSocket assistant endpoint**（§6）
4. **儀表板 → assistant 的內部通道**（Django Channels group 即可），把管理者的操作轉成 request

## 10. iOS 端會新增的 Request（後端可先預留，App 尚未實作）

```jsonc
{"request":{"data":{"setStreamId":{"id":"<uuid>"}},"id":N}}                    // 切換已設定的推流
{"request":{"data":{"setStreamUrl":{"url":"rtmp://...","key":"..."}},"id":N}}  // 任意推流（預設關閉）
{"request":{"data":{"showMessage":{"title":"...","subTitle":null,
                                   "severity":{"info":{}}}},"id":N}}           // 提示攝影師
{"request":{"data":{"setExposureBias":{"bias":0.5}},"id":N}}
{"request":{"data":{"setManualFocus":{"lensPosition":0.7}},"id":N}}
{"request":{"data":{"setStreamFps":{"fps":30}},"id":N}}
{"request":{"data":{"setBitrate":{"bitrate":6000000}},"id":N}}
```

這些 case 加進 Swift enum **不會**破壞舊 App：舊版收到不認得的 case 會 decode 失敗並記 log，
連線不會斷。但反過來，assistant 收到不認得的欄位要能容忍（用寬鬆解析）。

## 11. 待確認事項

- `control_token` 的輪替機制（管理者要能撤銷某台裝置的控制權）
- 一台裝置同時被 CTLive assistant 和攝影師自己的 Moblin assistant 連線時的行為
  （目前 App 只支援一個 streamer 連線，會互相搶）
- 預覽畫面的頻寬（`previewFps` 預設 1.0，行動網路上仍是可觀的量，建議儀表板不看時要送 `stopPreview`）
