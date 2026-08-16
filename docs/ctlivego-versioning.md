# CTLiveGo 版本管制

> CTLiveGo 是 Moblin 的 fork。這份文件說明版本號怎麼定、怎麼發、以及發版前要確認什麼。

## 1. 兩個版本號，各自獨立

| 欄位 | 位置 | 意義 |
|---|---|---|
| `MARKETING_VERSION` | `Config/Base.xcconfig` | **CTLiveGo 自己的版本**，例如 `1.0.0`。與 Moblin 無關 |
| `CURRENT_PROJECT_VERSION` | `Config/Base.xcconfig` | 建置編號。每次送 App Store / TestFlight **必須遞增** |
| `MOBLIN_UPSTREAM_VERSION` | `Config/Base.xcconfig` | **這份程式碼是從哪一版 Moblin 分出來的**。每次 rebase 後更新 |

為什麼要獨立：**出貨給賽事團隊的是這個 fork。** 沿用 Moblin 的版本號，對使用者而言不帶任何資訊 —— 他們不會知道「33.5.0」跟上一次拿到的版本差在哪。

為什麼要記 upstream：**一個 bug 到底是我們改壞的還是上游本來就有的，這是第一個要問的問題。** 沒有這個欄位就只能翻 git history 猜。App 內「關於」頁會同時顯示兩者。

三個都寫在 `Config/Base.xcconfig`，而不是各 target 各自設定 —— **App 與其擴充（Widget、Live Activity、Watch）的版本必須一致，否則 App Store 會拒收。**

## 2. 版本號怎麼跳

`主版本.次版本.修訂`

| 位置 | 什麼時候跳 |
|---|---|
| **主版本** | 現場作業方式改變。攝影師或導播需要重新學怎麼用 |
| **次版本** | 新功能，但既有操作方式不變 |
| **修訂** | 修 bug、效能、翻譯。功能沒有增減 |

判斷標準是**對現場的影響**，不是程式碼改了多少。一次大規模重構若使用者完全無感，那是修訂版。

## 3. 更新紀錄

`Moblin/View/Settings/About/AboutCtLiveVersionHistoryView.swift`，新的在最上面。

**只寫操作員或導播看得到的變化。** 內部重構、測試、文件屬於 git log，不屬於這裡 —— 更新紀錄是給現場的人看的，不是給我們自己看的。

上游 Moblin 的更新紀錄保留在 `AboutVersionHistorySettingsView.swift`，在「關於」頁另開一個入口。**兩者不要混在一起**：那份很長、寫給不同的讀者，混在一起就看不出「這次對我有什麼影響」。

## 4. 發版前確認

1. `MARKETING_VERSION` 已依 §2 調整
2. `CURRENT_PROJECT_VERSION` **已遞增**（漏掉會被 App Store 退件）
3. 若做過 rebase，`MOBLIN_UPSTREAM_VERSION` 已更新
4. `AboutCtLiveVersionHistoryView.swift` 已加上這一版的條目，日期正確
5. `make style-check`、`make lint`、測試全綠
6. 隱私權政策頁面（見 §5）內容與這一版的實際行為相符

## 5. 隱私權政策

App 內「關於 → 隱私權政策」指向 **`https://live.ctyeh.com/legal/privacy/`**。

由 CTLive 後端（ctyweb）提供，不是上游 Moblin 那份 —— **App Review 要求隱私權政策屬於出貨的人**，而上游那份描述的是另一個 App、另一群人在營運。

政策內容至少要涵蓋 CTLiveGo 實際會送出的東西：

- **位置**：持續上傳到 CTLive 後端（速度、距離、海拔），這是賽事轉播的核心功能
- **裝置狀態**：電量、機身溫度、網路狀態、是否在直播/錄影，透過遠端控制通道回報給導播
- **影音**：推流到設定的 ingest。CTLive 不會保存原始影像，除非使用者開啟錄影
- **裝置識別碼**：一組本機產生的 `IPHONE-xxxxxxxx`，存在 keychain，用於與後端配對。**不是 IDFA，不用於廣告**
- **推流金鑰**：存在 keychain，不寫進設定檔、不寫進 log

政策內容變更時，§4 第 6 項要重新確認。
