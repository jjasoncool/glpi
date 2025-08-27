## GLPI Docker Compose 使用說明

此目錄包含用於以 Docker Compose 部署 GLPI（Web）與 MariaDB 的設定與輔助腳本，並預設與 `zabbix` 使用相同的 `shared-network` 以便兩者互通。

### 目錄與檔案

- `docker-compose.yaml` - Compose 定義（`glpi` 與 `glpi-db`）。
- `init.sh` - 初始化腳本：建立必要目錄、從 `.env.template` 建 `.env`（若不存在），並建立 `shared-network`。
- `.env.template` - 範本環境變數。
- `.env` - 實際環境變數（不要提交到 git）。

### 架構重點

- GLPI 的應用資料使用 named volume `glpi-storage`，並透過 `driver_opts.device` 綁定到 `.env` 的 `GLPI_STORAGE_DIR`（預設 `./data/glpi`）。容器內路徑掛載為 `/var/www/html`。
- MariaDB 資料使用 named volume `glpi-db-data` 並綁定到 `.env` 的 `GLPI_DB_DATA_DIR`（預設 `./data/mariadb`）。
- 使用 external network `shared-network`（與 `zabbix` 相同），GLPI 可用 `zabbix-server` 作為 Zabbix 主機名稱。

### 必要環境（在 `./.env`）

以下為主要變數（可在 `.env.template` 找到）：

- `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_ROOT_PASSWORD` — MariaDB 連線設定。
- `DB_VER` — MariaDB 映像版本（選填）。
- `GLPI_STORAGE_DIR` — host 上的 GLPI 資料目錄（預設 `./data/glpi`）。
- `GLPI_DB_DATA_DIR` — host 上的 MariaDB 資料目錄（預設 `./data/mariadb`）。
- `GLPI_VERSION` — GLPI 映像 tag（預設 `latest`）。
- `TZ` — 時區（會傳入容器作為 `TZ`，若需設定 PHP `date.timezone`，請參閱下方建議）。

### 初始化（只做一次或需要重置時）

在包含 `docker-compose.yaml` 的目錄下執行（例如專案中的 `glpi` 資料夾）：

```bash
# 進到包含 compose 的目錄，然後執行初始化腳本
cd ./glpi   # 或使用你專案的實際路徑
./init.sh
# 編輯 .env，填入正確密碼與必要值
```

`init.sh` 會建立 `./data/glpi` 與 `./data/mariadb`（相對於該目錄），並產生 `.env`（若不存在）。

### 啟動服務

```bash
# 在包含 docker-compose 的目錄下啟動
cd ./glpi   # 或切換到你放置 compose 的目錄
docker compose up -d
```

預設外部存取：GLPI Web UI 對應到宿主機的 `8081`（`http://<host>:8081`）。

### 權限與備份

- 啟動後若出現無法寫入的情況，請調整資料目錄擁有者（根據容器內的 web user id）：

```bash
# 例如把 host 目錄擁有者設為 www-data (uid 33) 或適合你環境的使用者
sudo chown -R 33:33 ./data/glpi
```

- 定期備份 `./data/mariadb` 與 `./data/glpi`，或使用 `mysqldump` 備份資料庫。

### PHP 時區 (建議)

官方 `glpi/glpi` 映像未必有內建 `PHP_TZ` 環境變數。建議兩種方式：

1. 掛載一個 PHP config 檔到容器的 PHP `conf.d`，例如在宿主機建立 `timezone.ini`：

```ini
# timezone.ini
date.timezone = Asia/Taipei
```

然後在 `docker-compose.yaml` 對 `glpi` 服務掛入（路徑視映像 PHP 目錄而定）：

```yaml
services:
  glpi:
    volumes:
      - glpi-storage:/var/www/html:rw
      - ./docker/php/timezone.ini:/usr/local/etc/php/conf.d/timezone.ini:ro
```

2. 建自訂 Dockerfile 以 `FROM glpi/glpi:TAG` 並加入 `COPY timezone.ini /usr/local/etc/php/conf.d/`。

要檢查容器內 PHP 的 `date.timezone`：

```bash
docker compose exec glpi-web php -i | grep -i date.timezone
```

### 日誌與疑難排解

- 查看容器日誌：

```bash
docker compose logs -f glpi
docker compose logs -f glpi-db
```

- 若環境變數在啟動時未注入，檢查 `docker compose` 執行目錄是否含有正確的 `.env`（compose 會在執行目錄讀取 `.env`）。
- 如果你要共用一組 DB 變數（例如 `DB_HOST`），但容器需要特定名稱（例如 `GLPI_DB_HOST`），請在 `docker-compose.yaml` 的 `environment:` 使用 mapping，如：

```yaml
environment:
  GLPI_DB_HOST: ${DB_HOST:?DB_HOST is required}
```

這會把 `.env` 的 `DB_HOST` 傳入容器內的 `GLPI_DB_HOST`。

## setup.sh — 一鍵啟動與安裝完成清理

專案包含 `setup.sh`，提供一個簡單流程：執行 `init.sh`（若存在）、以 `docker compose up -d` 啟動服務，並在 GLPI 安裝完成後自動移除安裝器檔案 `install/install.php`。

使用方式：

```bash
cd /path/to/glpi
./setup.sh
```

可設定環境變數：

- `WAIT_TIMEOUT`：等待安裝完成的最大秒數，預設 `600`（10 分鐘）。
- `POLL_INTERVAL`：輪詢間隔（秒），預設 `5`。
- `CONTAINER_NAME`：目標 container 名稱，預設 `glpi`（可在執行前匯出或在 shell 中覆寫）。

判斷 GLPI 是否完成安裝的邏輯（腳本內實作）：

1. 確認容器內 `/var/glpi/config/config_db.php` 與 `/var/glpi/config/glpicrypt.key` 存在且非空。
2. 確認 GLPI 首頁能回應 HTTP 200（優先透過 host 的 port mapping 檢查 127.0.0.1:HostPort，若不可行則在 container 內使用 `curl` 檢查）。

注意：

- 若 host 無法直接存取 container（沒有對外映射 port）且 container 內沒有 `curl`，HTTP 檢查會失敗，腳本會視為尚未完成安裝並持續輪詢直到超時。
- 若在安裝尚未完成時強制移除安裝器，可能造成系統無法正確安裝或運作；若確定要強制移除，手動執行：

```bash
docker exec glpi rm -f /var/www/glpi/install/install.php
```
---
