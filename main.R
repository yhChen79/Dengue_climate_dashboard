library(httr)
library(jsonlite)
library(tidyverse)
library(lubridate)
library(purrr)
library(googlesheets4)

cat("=== 步驟 0: Google 試算表雲端身分驗證 ===\n")
# 1. 金鑰
gs4_auth(path = "dengue-project-eic02-63f1bd69bb33.json")

# 2. Google 試算表網址
ss_url <- "https://docs.google.com/spreadsheets/d/1f-Vh9YbN4MMqgN3K72-jPg9dDXzISSiQY00AW20TRds/edit"

cat("\n=== 步驟 1: 從 Google Sheets 讀取輸入資料 ===\n")
# 氣象要素、測站資訊、大疫情年份設定
climate_items <- read_sheet(ss_url, sheet = "climate_items")
station_id    <- read_sheet(ss_url, sheet = "station_id")
big_epi_year_ref <- read_sheet(ss_url, sheet = "big_epi_year")


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


# ==========================================
# 4. 資料橫向合併與疫情年份三階段分類 (epi_year)
# ==========================================
cat("\n進行資料合併與疫情年份分類...\n")

# 確保對照表的資料型態與主表一致
big_epi_year_ref <- big_epi_year_ref %>%
  mutate(
    city = as.character(city),
    year = as.integer(year),
    is_big = "Yes" # 標記在表內的都是大流行
  )

# 先合併 CWA 與 NOAA
df_merged_temp <- df_cwa_final %>%
  left_join(df_noaa_final, by = c("year", "month"))

# 年份分類邏輯
df_merged_all <- df_merged_temp %>%
  mutate(city = as.character(city)) %>% 
  left_join(big_epi_year_ref, by = c("city", "year")) %>%
  mutate(
    epi_year = case_when(
      year == current_year ~ paste0(current_year, "年"),   # 1. 如果年份等於今年，歸類為 this_year
      is_big == "Yes"      ~ "大疫情年份",         # 2. 如果在對照表內有對到，歸類為 big
      TRUE                 ~ "非大疫情年份"        # 3. 其餘所有年份，通通歸類為 small
    )
  ) %>%
  select(-is_big) # 移除暫存欄位

cat("\n=== 將合併後的最終大表寫回 Google Sheets ===\n")
sheet_write(df_merged_all, ss = ss_url, sheet = "merged_data")


# ==========================================
# 5. 登革熱病例數資料
# ==========================================

# 年月連續
full_list <- crossing(
  city = c("tainan", "kao"),  
  year = 2002:current_year,
  month = 1:12
)

# OpenData [登革熱1998年起每日確定病例統計] 下載網址
dengue_case_csv_url <- "https://od.cdc.gov.tw/eic/Dengue_Daily.csv"
dengue_case_linelist <- read.csv(dengue_case_csv_url, fileEncoding = "UTF-8", stringsAsFactors = FALSE)

# 整理資料
dengue_case <- dengue_case_linelist %>%
    filter(是否境外移入 == "否" & 居住縣市 %in% c("台南市","高雄市")) %>%
    mutate(date = coalesce(na_if(個案研判日, ""), na_if(通報日, "")),
           year = year(as.Date(date)),
           month = month(as.Date(date)),
           city = case_when(居住縣市 == "台南市" ~ "tainan",
                               居住縣市 == "高雄市" ~ "kao")) %>%
    count(year, month, city, name = "case")

dengue_case_data <- full_list %>%
    left_join(dengue_case, by = c("city", "year", "month")) %>%
    mutate(case = coalesce(case, 0)) %>%
    filter(year < current_year | (year == current_year & month <= current_month))

# 匯出到 google sheet
sheet_write(dengue_case_data, ss = ss_url, sheet = "dengue_data")
