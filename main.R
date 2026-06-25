library(httr)
library(jsonlite)
library(dplyr)
library(tidyr)
library(purrr)
library(googlesheets4)

cat("=== 步驟 0: Google 試算表雲端身分驗證 ===\n")
# 1. 金鑰
gs4_auth(path = "dengue-project-eic02-63f1bd69bb33.json")

# 2. Google 試算表網址
ss_url <- "https://docs.google.com/spreadsheets/d/1f-Vh9YbN4MMqgN3K72-jPg9dDXzISSiQY00AW20TRds/edit"

cat("\n=== 步驟 1: 從 Google Sheets 讀取輸入資料 ===\n")
# 氣象要素、測站資訊
climate_items <- read_sheet(ss_url, sheet = "climate_items")
station_id    <- read_sheet(ss_url, sheet = "station_id")


# ==============================================================================
# PART 1. 抓取中央氣象署 (CWA) 觀測資料
# ==============================================================================
cat("=== 步驟 1: 開始抓取中央氣象署 (CWA) 資料 ===\n")

url <- "https://codis.cwa.gov.tw/api/station"



# 萃取出獨立的主要素清單
true_top_items <- unique(sapply(strsplit(climate_items$detail, "\\."), `[`, 1))
all_stations_list <- list()

# 雙重迴圈下載 CWA 資料
for (i in 1:nrow(station_id)) {
  stn <- station_id[i, ]
  cat(sprintf("\n🚀 正在處理測站 [%s] %s ...\n", stn$ID, stn$name_CHT))
  stn_elements_list <- list()
  
  for (element in true_top_items) {
    cat(sprintf("   -> 正在下載要素: %s ... ", element))
    
    api_item <- element
    if (element == "WindSpeed" || element == "WindDirection") {
      api_item <- "WindSpeed,WindDirection"
    }

    my_payload <- list(
      date     = "2026-01-01T00:00:00+08:00",
      type     = "one_year",
      stn_ID   = as.character(stn$ID),
      stn_type = as.character(stn$stn_type),
      more     = "",
      start    = paste0(stn$Data_Start_Year, "-01-01T00:00:00"), 
      end      = "2026-12-31T00:00:00",                          
      item     = api_item  
    )
    
    response <- POST(url, body = my_payload, encode = "form")
    
    if (status_code(response) == 200) {
      json_text <- content(response, as = "text", encoding = "UTF-8")
      data_list <- fromJSON(json_text)
      
      if (!is.null(data_list$month$data$dts) && length(data_list$month$data$dts) > 0) {
        df_month <- data_list$month$data$dts[[1]]
        df_flat <- jsonlite::flatten(df_month)
        target_details <- climate_items$detail[sapply(strsplit(climate_items$detail, "\\."), `[`, 1) == element]
        
        df_cleaned <- df_flat %>% 
          select(DataYearMonth, any_of(target_details))
        
        stn_elements_list[[element]] <- df_cleaned
        cat("✅ 成功\n")
      } else {
        cat("⚠️ 無資料\n")
      }
    } else {
      cat(sprintf("❌ 失敗 (狀態碼: %d)\n", status_code(response)))
    }
    Sys.sleep(0.4)
  }
  
  # 測站內部多要素橫向合併
  if (length(stn_elements_list) > 0) {
    stn_merged <- stn_elements_list %>% reduce(left_join, by = "DataYearMonth")
    
    stn_merged$stn_ID   <- stn$ID
    stn_merged$name_CHT <- stn$name_CHT
    stn_merged$name_ENG <- stn$name_ENG
    stn_merged$city     <- stn$city
    stn_merged$location <- stn$location
    
    all_stations_list[[as.character(stn$ID)]] <- stn_merged
  }
}

# 合併所有 CWA 測站資料
cat("\n整合所有 CWA 測站數據中...\n")
df_all_raw <- bind_rows(all_stations_list)

current_year  <- as.integer(format(Sys.Date(), "%Y"))
current_month <- as.integer(format(Sys.Date(), "%m"))
rename_vec    <- setNames(climate_items$detail, climate_items$nickname)

df_cwa_final <- df_all_raw %>%
  mutate(
    year  = as.integer(substr(DataYearMonth, 1, 4)),
    month = as.integer(substr(DataYearMonth, 6, 7))
  ) %>%
  filter(year < current_year | (year == current_year & month <= current_month)) %>%
  select(
    stn_ID, name_CHT, name_ENG, city, location, 
    DataYearMonth, year, month, 
    any_of(rename_vec)
  )


# ==============================================================================
# PART 2. 抓取 NOAA 最新聖嬰數據
# ==============================================================================
cat("\n=== 步驟 2: 開始抓取 NOAA 聖嬰現象數據 ===\n")

noaa_url <- "https://www.cpc.ncep.noaa.gov/data/indices/sstoi.indices"
nino_data_raw <- read.table(noaa_url, header = TRUE, sep = "", stringsAsFactors = FALSE)

df_noaa_final <- nino_data_raw %>%
  mutate(
    year  = as.integer(YR),
    month = as.integer(MON),
    Date  = as.Date(paste(YR, MON, "01", sep = "-"))
  ) %>%
  select(
    year, month, Date,
    NINO1.2_SST  = NINO1.2,
    NINO1.2_ANOM = ANOM,
    NINO3_SST    = NINO3,
    NINO3_ANOM   = ANOM.1,
    NINO4_SST    = NINO4,
    NINO4_ANOM   = ANOM.2,
    NINO3.4_SST  = NINO3.4,
    NINO3.4_ANOM = ANOM.3
  )
cat("✅ NOAA 數據截取與清洗完成\n")


# ==============================================================================
# PART 3. 資料橫向合併 (CWA + NOAA)
# ==============================================================================
cat("\n=== 步驟 3: 執行資料橫向合併 (以 Year 和 Month 對齊) ===\n")

# 使用 left_join，以 CWA 資料為主體，合併對應年月份的 NOAA 指數
df_merged_all <- df_cwa_final %>%
  left_join(df_noaa_final, by = c("year", "month"))

cat("🎉 全部資料合併完成！\n")
cat(paste("最終資料列數：", nrow(df_merged_all), "列\n"))
cat(paste("欄位清單：\n", paste(colnames(df_merged_all), collapse = ", "), "\n"))


cat("\n=== 步驟 4: 將合併後的最終大表寫回 Google Sheets ===\n")
sheet_write(df_merged_all, ss = ss_url, sheet = "merged_data")

