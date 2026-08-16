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
{"event":{"data":{"status":{"general":{...},"topLeft":{...},"topRight":{...}}}}}
{"event":{"data":{"state":{"data":{...}}}}}
{"preview":{"preview":"<base64 JPEG>"}}
```

要點：

- **物件內欄位順序不固定**（Swift 沒有保證），不要依賴順序
- `request.id` 是 assistant 給的遞增整數，streamer 會用同一個 id 回 `response`
- 沒有結果的指令回 `{"response":{"id":N,"result":{"ok":{}},"data":null}}`
- streamer 送 `{"ping":{}}` 的節奏是 **連上後第 5 秒送第一次，之後每 15 秒**（不是 30 秒）。
  送出後起一個 **10 秒 deadline**，逾時就判定半開並重建連線。
  **assistant 應該回 `{"pong":{}}`**，但 App 端不再單靠這個：
  **收到 assistant 的任何一則訊息都會重置該 deadline**，所以沒實作 JSON pong 的
  assistant 只要連線上有其他流量就不會被誤判。真正的半開（完全沒有 inbound）仍會被抓到。
- pong 不保證是 ping 之後的下一則 frame。assistant 可能先送 getStatus / startStatus
  等 request，pong 排在後面。只讀下一則 frame 來判斷會誤判
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

`startStatus` 的 `interval` 單位是秒。`filter.topRight` 為 true 時只送 general + topRight（省流量）。

App 端不會枯等 `startStatus`：**CTLive 控制連線一旦 identified 成功就會立刻送一次 status
並開始週期回報**，弱網重連時少一個往返。assistant 之後送的 `startStatus` 照樣生效（會改成
它要的 filter），`stopStatus` 也照樣會停。

### 8.1 status 的實際形狀（實機輸出，2026-08-16 驗證）

**這是最容易寫錯的地方**：`isLive` 在 `general` 底下，不是頂層。

```json
{"event":{"data":{"status":{
  "general":{"isLive":false,"isRecording":false,"isMuted":false,
             "batteryLevel":55,"batteryCharging":false,"flame":"White"},
  "topLeft":{"stream":{"message":"測試A (1080p, 30, SRT, H.265 ABR <5 Mbps, AAC 128 Kbps)","ok":true},
             "camera":{"message":"後置 三鏡頭（低耗電）"},"mic":{"message":"下"}},
  "topRight":{"remoteControl":{"message":"實況主"},"moblink":{"message":"","ok":true},
              "audioLevel":{"message":"-24 dB，1 ch"}}
}}}}
```

| 欄位 | 實際形狀 | 常見誤解 |
|---|---|---|
| `general.isLive` / `isRecording` | 在 `general` 底下 | 不在頂層 |
| `general.batteryLevel` | **Int 0–100**（`55`） | 不是 0.55 的 float |
| 機身溫度 | `general.flame`，字串 `"White"` / `"Yellow"` / `"Red"`（首字大寫） | 沒有 `thermalState` 欄位 |
| `topRight.moblink` | `{"message":"...","ok":bool}`，未連線時 message 是空字串 | 不是 `{"ok":true}` |
| `topRight.*` | **只在該功能啟用時才出現**（`bitrate` / `uptime` / `srtla` 只在直播中有） | 不可當必填 |

assistant 若靠 `isLive` 決定「這個指令會不會切斷直播」，**務必讀 `status.general.isLive`**。
讀錯路徑會永遠讀不到，結果等同於保護失效。

## 9. 需要 CTLive 後端配合新增的 API

1. **redeem 回應多帶 `control_token`**（每裝置一組隨機字串，用於 remote control 密碼）
   - 現有 redeem 回應：`device_id`, `device_internal_id`, `owner_username`, `owner_id`, `bound_at`, `created`
   - 新增：`control_token`（String）、`control_url`（String，wss URL）
   - App 端會把這兩個存起來自動設定 remote control
2. **check 回應也帶同樣兩個欄位**（App 重裝或換機後要能拿回來）
3. **WebSocket assistant endpoint**（§6）
4. **儀表板 → assistant 的內部通道**（Django Channels group 即可），把管理者的操作轉成 request

## 10. 推流設定同步（已實作，2026-08-16 端對端驗證通過）

產品目標：**現場攝影師專心拍攝，不碰手機。推流位址與啟用切換全在網頁完成。**

`setStreamUrl` 這條路沒有走。改成由儀表板下發一整份 profile 清單：

```jsonc
{"request":{"id":N,"data":{"setStreamProfiles":{"profiles":[
  {"id":"<不透明字串>","name":"YouTube 主頻道","protocol":"rtmp",
   "url":"rtmp://a.rtmp.youtube.com/live2","streamKey":"...","isActive":true}
]}}}}
{"request":{"id":N,"data":{"setActiveStreamProfile":{"id":"<不透明字串>"}}}}
```

兩者共用同一個 response case（Swift Codable 的關聯值一律包一層 case 名，**不是扁平的**）：

```jsonc
{"response":{"id":N,"result":{"ok":{}},"data":{"setStreamProfiles":{"appliedId":"<id>"}}}}
```

`appliedId` 是**手機實際正在推的那一組**，不是被要求的那一組。三態語意：

| 值 | 語意 |
|---|---|
| `null` | App 沒回這則 response（連線斷、或舊版 App）→ 不判定 |
| `""` | 明確：目前推的不是任何一組 CTLive 管理的 profile |
| 有值 | 實際推流中的那組。與儀表板的啟用組不符時，儀表板應顯示「待生效」 |

### 10.1 App 端行為（重點在「絕不切斷正在進行的轉播」）

- `id` 當**不透明字串**，不 parse 成 UUID
- 以 `id` upsert；清單中沒有的本地設定刪除，**唯一例外**是「要刪的正好是目前使用中的 stream」則保留並記 log
- **直播中收到 `setStreamProfiles` 只存檔、不重載推流**，`appliedId` 回原本那組
- **直播中收到 `setActiveStreamProfile` 也只存檔、不切換** —— 這偏離「後端保證不在直播中送出」的原始規格，
  是刻意的防守：後端偵測 `isLive` true→false 才補送，而 status 每秒一則，
  它看到的 false 至少是一秒前的值，攝影師可能在那個空檔重新開播。
  切換的代價是斷播，存檔的代價只是延後 —— 後端下次停播會再送一次（`applied != desired` 仍成立）
- **URL 沒有實際變動就不重載**。儀表板每次重連都會重送整份清單，
  無條件重載會讓攝影師的預覽在每次網路抖動時閃一下
- `protocol` 只接受 `rtmp` / `rtmps` / `srt`（大小寫不拘），其他值該筆忽略並記 log

### 10.2 URL 組裝

Moblin 的 `SettingsStream` 只有一個 `url`，stream key 是接在裡面的：

| 情況 | 結果 |
|---|---|
| `rtmp://host/live2` + key `abc` | `rtmp://host/live2/abc` |
| `rtmps://host/live/` + key `abc` | `rtmps://host/live/abc`（不會有雙斜線） |
| `srt://host:8890` + key 空 | 原樣 |
| `srt://host:8890` + key `r1` | `srt://host:8890?streamid=r1` |
| `srt://host:8890?latency=2000` + key `r1` | `...?latency=2000&streamid=r1` |
| url 裡已有 `streamid=` | **url 勝出**，不再追加 |

`?streamid=` 就是 Moblin 既有的 SRT 慣例，不是這裡發明的。

### 10.3 儲存與保密

- profiles 存 **Keychain**（`kSecAttrAccessibleAfterFirstUnlock`），重開 App / 重開機 / 重裝都在
- settings 檔裡的鏡像 stream **刻意不寫 url**（url 含 streamKey），開 App 時從 Keychain 還原。
  因此 `ctLiveLoadStreamProfiles()` 必須在 `setCurrentStream()` **之前**跑
- `streamKey` 與 `url` 已在 `redactSensitiveJsonValues` 的遮蔽清單中，不會入 log
- UI 上 CTLive 管理的 stream：URL 遮蔽顯示、不可點進去編輯、不可滑動刪除，並標「Managed by CTLive」
- 使用者手動「複製」一份出來的複本**不帶 CTLive 標記**，會變成一般本地 stream，
  不會被下次同步刪掉。這是刻意留的逃生口

## 10.4 尚未實作的 Request（後端可先預留）

```jsonc
{"request":{"data":{"showMessage":{"title":"...","subTitle":null,
                                   "severity":{"info":{}}}},"id":N}}           // 提示攝影師
{"request":{"data":{"setExposureBias":{"bias":0.5}},"id":N}}
{"request":{"data":{"setManualFocus":{"lensPosition":0.7}},"id":N}}
{"request":{"data":{"setStreamFps":{"fps":30}},"id":N}}
{"request":{"data":{"setBitrate":{"bitrate":6000000}},"id":N}}
```

這些 case 加進 Swift enum **不會**破壞舊 App：舊版收到不認得的 case 會 decode 失敗並記 log，
連線不會斷。但反過來，assistant 收到不認得的欄位要能容忍（用寬鬆解析）。

## 11. 連線韌性與 close code 語意

### 11.1 close code 怎麼讀

| code | 意義 | assistant 該做什麼 |
|---|---|---|
| **1001** | **App 主動拆線**（設定變更、watchdog 重建） | 正常，等它幾秒內回來 |
| **1006** | 沒有 close frame —— 真的斷網，或 App 沒能好好收尾 | 環境問題，看它會不會自己回來 |
| 4001 | 憑證撤銷 | App **不會**重連，要重新配對才會回來 |
| 4004 | 未配對 / 控制被停用 | App 60 秒後才會再試 |

`NWConnection.cancel()` 本身**不送 close frame**，所以早期版本任何 App 端主動拆線在後端都長成
1006，害後端把自家行為誤判成網路故障。現在拆線前會先送 `goingAway`(1001) 再 cancel，
**1001 與 1006 因此是可信的區分訊號**。

### 11.2 重連退避

CTLive 控制連線是 **3s → 6s → 12s → 24s → 上限 30s，每次 ±20% jitter**
（其他 Moblin websocket 維持原本的 0.5s / 10s）。連上後歸零。

另外有一層 watchdog：控制連線持續斷線超過 30 秒就整個重建 streamer。

### 11.3 `reloadRemoteControlStreamer()` 必須是冪等的

`reloadStream()` → `reloadConnections()` 會重建**所有**對外連線，遠端控制也在那份清單裡。
所以「切換推流目標」「檢查配對」「reload chat」都會連帶把控制連線拆掉重建。

這在轉播現場最不能接受：發生時機正好是**導播剛按下切換的那一刻**，弱網下退避可能要幾十秒，
導播會在自己操作之後立刻失去畫面與狀態。

現在的做法是：**URL 與憑證都沒變、而且連線是活的，就直接 return，不重建。**
一次擋掉所有觸發路徑，而不是逐條去堵。watchdog 不受影響 —— 它只在連線已經死掉時觸發，
那時 `isConnected()` 是 false，照樣會重建。

2026-08-16 兩條路徑都實測過，控制連線皆零斷線：

- 切換到**另一組** profile（`guard target.id != stream.id` 的主路徑）
- **同一組** profile 的 url 變更（else 分支：目標就是當前 stream，
  但 `changed.contains(active.id)` 成立 → 仍會 `reloadStream()`）

第二條容易被漏測，因為它需要「目標沒換、內容換了」這個組合。

## 12. 現場部署前提（iOS 裝置設定）

**這幾項是背景存活的必要條件**，攝影師會把手機放進口袋、螢幕會關掉，
App 必須在那個狀態下還活著。

⚠️ **但要說清楚因果**：2026-08-16 測試中那幾次斷線（156s / 170s / 189s）
**沒有被證實**是這些設定造成的。當天沒有人確認過裝置實際的設定值，
而事後得知**手機當時一直在移動中**（status 的 `topRight.location` 顯示 11 km/h），
所以「行動網路事件」（基地台交接、訊號衰減、路徑切換）是更簡潔的解釋。

**A1/A2 該設，但不要把它們寫成當天斷線的原因。** 那是我們推論過但從未驗證的假設。

| 設定 | 值 | 為什麼 |
|---|---|---|
| 設定 → 螢幕顯示與亮度 → 自動鎖定 | **永不** | 螢幕關閉後 App 可能被 iOS 暫停 |
| 設定 → Moblin → 位置 | **永遠** | Moblin 靠持續的位置更新換取背景執行權。只給「使用 App 期間」的話這個機制完全不成立 |
| 低耗電模式 | 關閉 | 會影響背景活動（尚未實測，賽事前應確認） |
| App 內 設定 → CTLive | 已配對且「允許遠端控制」已開 | 否則不會建立控制連線 |
| 推流目標可達性 | 賽事前實測一次 | 見下 |

**診斷方法**：App 被凍住時，App 端**連 `Disconnected` handler 都不會執行**
（`remote-control-streamer: Disconnected after N s connected` 與
`websocket: Disconnected ... with close code N` 兩行都是 info 層級，都不會出現）。
若只是網路斷而 App 活著，10 秒的 WS ping timer 或 `NWConnection` 的 error handler
至少會觸發一個並記 log。**「後端看到斷線但 App 端一片安靜」就是被凍住。**

反過來也要小心：**後端無法區分「App 自動重連」與「有人手動重啟 App」**，
兩者在 assistant 端長得一模一樣。判定自動恢復之前必須先確認那段時間沒有人為操作。

### 12.1 推流位址

正式的 SRT 推流目標是 **`live.ctyeh.com:8890`**（mediamtx），streamid 格式 `publish:<名稱>`：

```
url       = srt://live.ctyeh.com:8890
streamKey = publish:bike1
→ 組出 srt://live.ctyeh.com:8890?streamid=publish:bike1
```

2026-08-16 的測試中推流四次全部 `SRT error: connect timer expired`，
根因是測試 profile 填了 `relay.ctyeh.com`，**那個 hostname 不存在於 DNS**。
App 端的 URL 組裝與 Moblin 的 SRT 實作都沒有問題。

改成正確位址後同日驗證通過，relay 端證實收到實際資料：

```
path=bike1  ready=True  source=srtConn  tracks=['H265','MPEG-4 Audio']
bytesReceived=3,592,122
```

教訓值得記著：**`isLive=true` 只代表 App 認為自己在推流，不代表資料真的出得去。**
同一份程式碼、同樣的 `isLive=true`、面板一切正常，一次是 3.6 MB 真的流過去，
一次是一個 byte 都沒有。**賽前必須實際推 30 秒並在 relay 端確認收到。**

mediamtx 目前 `srtPublishPassphrase: ""` 且 publish/read 對任何人開放（戶外直播的方便性取捨），
代表任何知道位址的人都能推流覆蓋。正式賽事前值得評估。

## 13. 待確認事項

- `control_token` 的輪替機制（管理者要能撤銷某台裝置的控制權）
- 一台裝置同時被 CTLive assistant 和攝影師自己的 Moblin assistant 連線時的行為
  （目前 App 只支援一個 streamer 連線，會互相搶）
- 預覽畫面的頻寬（`previewFps` 預設 1.0，行動網路上仍是可觀的量，建議儀表板不看時要送 `stopPreview`）
