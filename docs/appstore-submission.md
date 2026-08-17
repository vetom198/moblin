# CTLiveGo App Store 上架工作單

2026-08-17 起草。單一事實來源：上架流程中每個決定、每個待辦、每個風險都記在這裡。

## 現況盤點（已驗證）

| 項目 | 狀態 |
|---|---|
| Bundle ID | `app.cycledash.moblin`（裝置建置已可簽，代表 portal 上已註冊） |
| Team | `CK5LK2R722` |
| 版本 | MARKETING_VERSION 1.0.0 / build 1 |
| App 圖示 | 1024×1024 單一尺寸，已就位 |
| 顯示名稱 | CTLiveGo（`CFBundleDisplayName`，各語言一致） |
| 加密聲明 | `ITSAppUsesNonExemptEncryption = NO` 已在 Info.plist。CTLiveGo 與上游同樣內建 SRT 的 AES passphrase 加密（標準演算法的第三方實作，非僅 OS TLS）。標準演算法屬豁免類（5A992.c mass market），上游 Moblin 亦以此設定上架多年；維持 NO，但嚴格說每年應向美 BIS 提自我分類報告——先照上游慣例，記錄在案 |
| 隱私權政策 | https://live.ctyeh.com/legal/privacy/ （200，免登入，內容經雙向查核） |
| 服務條款 | https://live.ctyeh.com/legal/terms/ （200；非必填但已備） |
| Entitlements | `CAPABILITIES = free`：只有 external-accessory wireless-configuration |
| 背景模式 | audio, location, bluetooth-central, **voip** |
| 附屬目標 | Watch App、Widget、Live Activity、Screen Recording extension 均隨主程式打包 |

## 定案路線（CycleDashGo 實證 + 本機驗證，2026-08-17）

**全部走 Xcode Cloud。** CycleDash 踩過同一個坑：本機 beta 工具鏈 archive
上傳一律被 **ITMS-90111** 拒收，無繞過方法；正式版 Xcode 在 macOS beta 上
不受支援。本機只做開發與裝置測試。

已驗證可用的資源：
- **ASC API key**（team-scoped）：`ASC_KEY_ID=M5JZQ2KHXX`、
  `ASC_ISSUER_ID=e59f6b0a-…`，金鑰在 `~/.appstoreconnect/private_keys/`，
  env 已在 `~/.zshrc`。本 session 已實測能列 apps / bundleIds。
  （同目錄的 `AuthKey_LPV224Q997.p8` 是舊的，不要用。.p8 絕不進 repo。）
- **送審腳本**：`~/Code/CycleDashGo/scripts/appstore-release.py` 可抄，
  改檔頭 `BUNDLE_ID` 即可。注意：版本說明帶 emoji 會被 API 以 409 打回。
- **GitHub ↔ Xcode Cloud 已授權**（scmProvider id `8782009b-…`，已接
  `vetom198/CycleDashGo`）；加 `vetom198/moblin` 只需在 GitHub 的
  Xcode Cloud App 設定勾 repo。

### 步驟（依序）

1. [ ] ASC 網頁建立 App 紀錄（bundle id `app.cycledash.moblin`，API 建不了）
2. [ ] GitHub Xcode Cloud App 加 `vetom198/moblin` 的 access
3. [ ] ASC 建 workflow：branch **`refine`**、單一 ARCHIVE、scheme `Moblin`
       （已確認是 shared scheme）、**Environment 鎖 Latest Release Xcode
       （兩處都要確認，鎖錯等於回到 beta）**、
       buildDistributionAudience = APP_STORE_ELIGIBLE
4. [ ] push → 等 TestFlight build（Moblin 帶 libsrt 等原生依賴，單次建置
       比 CycleDash 久很多；前幾次建完看一下 25 小時/月的用量）
5. [ ] 補 metadata / 截圖 / 分級問卷 / App Privacy / review notes + demo
6. [ ] 抄 `appstore-release.py` → `submit --version 1.0.0 --wait`

### 已完成的本機準備

- [x] `Config/User.xcconfig` 進版控（Xcode Cloud 的 clean clone 需要它；
      Base.xcconfig 第一行就 include 它，缺了整個 bundle id 都是空的）
- [x] shared scheme 確認存在（`Moblin.xcscheme`）
- [x] ASC API key 實測可用

### 已知風險與注意（Xcode Cloud）

- ASC 網頁編輯 workflow 可能把 `branchStartCondition` 弄成 null（push 不再
  觸發且無警告）。診斷：`GET /v1/ciWorkflows/{id}`；可 PATCH 修回。
- `ciBuildRuns` 要走 `/v1/ciWorkflows/{id}/buildRuns?sort=-number`。
- build 號由 Xcode Cloud 自動遞增，`CURRENT_PROJECT_VERSION` 會被忽略；
  只維護 MARKETING_VERSION。
- **附屬 bundle id（.Watch / .Moblin-Capture / .LiveActivity / .Watch.Widget）
  目前不在 portal 上**（本機 dev 簽章用萬用 profile 混過去了）。Xcode Cloud
  的雲端簽章理論上會自動註冊；第一次建置若 fail，先查這裡。
- PLA 合約沒簽會同時噴 `PLA Update available` + `No signing certificate`，
  看起來像簽章問題，其實是合約。

## 待辦（人力）

- **審查 demo 環境**：核心功能要配對 CTLive 儀表板。審查員需要一組能用的
  配對碼或 demo 帳號 + 操作步驟（ASC 的 demoAccountName/Password 欄位 +
  review notes；最好附操作影片）→ 要請 CTLive session 準備。
  「reviewer 無法完成核心流程」是這類 App 最常見退件原因。

## ⚠️ 審查風險（先認清單，不動）

- **`voip` 背景模式**：上游 Moblin 以同一份 plist 上架成功，先不動；
  若被退再處理（風險：iOS 13 起 voip 模式理論上要求 CallKit）。
- **背景定位（Always）**：用途是「將位置持續傳給賽事儀表板」。
  權限文案已寫明（`NSLocationAlwaysAndWhenInUseUsageDescription`），
  審查備註要再解釋一次為什麼需要 Always。
- **設定被鎖**：App 內大量功能被管理鎖藏起來（設計如此）。要在審查備註
  講清楚這是 MDM-style 的受管裝置 App，避免審查員以為功能缺失。

## App Store Connect 欄位草稿

- **名稱**：CTLiveGo
- **副標**（30 字內）：賽事多機直播相機（草稿，待定）
- **主要語言**：zh-Hant？（待使用者確認；上架地區同樣待確認）
- **類別**：Sports（主）/ Photo & Video（次）（草稿）
- **支援網址**：https://live.ctyeh.com/
- **隱私權政策網址**：https://live.ctyeh.com/legal/privacy/
- **描述**（草稿，zh-Hant）：

  > CTLiveGo 是 CTLive 賽事轉播平台的相機端 App。與 CTLive 儀表板配對後，
  > 導播即可遠端開關直播與錄影、切換場景、調整位元率，並即時看到每台
  > 裝置的電量、溫度與連線狀態。專為自行車等長距離賽事的多機轉播設計：
  > 支援 SRTLA 多路網路聚合、螢幕鎖定時保持連線、GPS 位置即時回傳。
  > 本 App 基於開源專案 Moblin 開發。

- **關鍵字**（100 字元，草稿）：live,streaming,race,broadcast,SRT,SRTLA,RTMP,直播,賽事,轉播
- **審查備註**（草稿，英文，重點）：
  - Managed-device app for race broadcasting; most settings are
    intentionally locked and configured remotely from our dashboard.
  - Demo pairing instructions: <待 CTLive 提供>
  - Background location keeps the device reachable by the race director
    and feeds the live tracking map; this is the app's core purpose.

### App 隱私（資料蒐集問卷）依據

依 https://live.ctyeh.com/legal/privacy/ 填：

| 類別 | 蒐集 | 連結身分 | 追蹤 |
|---|---|---|---|
| 精確位置 | 是（持續，賽事追蹤） | 是（裝置綁定帳號） | 否 |
| 音訊/影片（使用者內容） | 是（直播） | 是 | 否 |
| 裝置 ID（自建配對碼，非 IDFA） | 是 | 是 | 否 |
| 診斷（電量、溫度、連線品質） | 是 | 是 | 否 |
| 第三方分析/廣告 | 無 | — | — |

## 素材待辦

- [ ] 截圖：6.9"（iPhone 16 Pro Max = CHIPhone 可直接擷取）必備；
      建議畫面：主畫面（新控制列）、CTLive 配對頁、直播中總覽
- [ ] Watch App 截圖（隨附 Watch app 需要）
- [ ] 副標、描述、關鍵字定稿（含英文版與否，待定地區）

## 流程紀錄

- 2026-08-17：盤點完成；beta 工具鏈問題確認；已向 CycleDashGo 詢問
  帳號狀態、上傳路徑、Xcode Cloud 經驗（問題 1–7）。
