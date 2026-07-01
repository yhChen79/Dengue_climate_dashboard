
## 專案目標
本專案旨在建立一個每日自動更新的公開網頁儀表板，整合臺灣疾病管制署 (CDC)、臺灣氣象署 (CWA) 與美國國家海洋暨大氣總署 (NOAA) 的跨領域公開資料。透過動態趨勢圖表，比較登革熱大疫情年份及非大疫情年份的氣候趨勢。

## 資料來源
`臺灣疾病管制署(CDC)公開資料` https://od.cdc.gov.tw/eic/Dengue_Daily.csv

`臺灣氣象署(CWA)公開資料` https://codis.cwa.gov.tw/api/station

`美國國家海洋暨大氣總署(NOAA)公開資料` "https://www.cpc.ncep.noaa.gov/data/indices/sstoi.indices"


## 技術專案特點
- 雲端無伺服器架構
- 零經費維護成本：全採用免費的開源與雲端工具（GitHub, Google Sheet, Looker Studio）
- 混合式自動化排程：結合Git Actions與本機排程，彈性繞過CDC Open Data會擋境外IP的限制。


## 系統架構與資料流 (Data Pipeline)
1. **資料源觸發**：
   * **[臺灣CDC登革熱病例數資料]** ➔ 每日定時由 **[本機工作排程器]** 啟動 Rscript 抓取（避開境外 IP 限制）➔ 下載並直接上傳至 **[Google Sheets]**。
   * **[CWA 氣象 / NOAA 海溫 API]** ➔ 每日定時由 **[GitHub Actions 雲端]** 自動發出請求 ➔ 線上進行抓取、合併與清洗。
2. **資料中樞儲存**：
   * 兩路資料最終匯流至 **[Google Sheets]**，作為本專案的輕量級資料庫。
3. **前端即時呈現**：
   * **[Looker Studio 儀表板]** 即時同步 Google Sheets，動態更新視覺化圖表。


## 資料庫結構
`Google Sheet`: https://docs.google.com/spreadsheets/d/1f-Vh9YbN4MMqgN3K72-jPg9dDXzISSiQY00AW20TRds/edit

頁籤

`station_id` 納入測站及其基本資訊

`climate_items` 納入氣象要素

`big_epi_year` 大疫情年份設定

`merged_data` 彙整年、月、縣市、氣象資料、海溫資料

`dengue_case_data` 每月本土登革熱病例數
