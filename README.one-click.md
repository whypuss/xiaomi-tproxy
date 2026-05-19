# AX9000 xray 透明代理 — 一鍵部署腳本

**分支:** `one-click-deploy` — 獨立一鍵部署版本，唔改動 `main` 分支

---

## 適用情況

- 從未喺 AX9000 部署過，想一步完成
- 唔想睇 README / 唔想記指令
- 祇需要提供：路由器 IP、SSH 密碼、VLESS URL、代理網站

---

## 使用方式

### 1. 下載腳本

```bash
curl -O https://raw.githubusercontent.com/whypuss/xiaomi-tproxy/one-click-deploy/ax9000-tproxy-deploy.sh
chmod +x ax9000-tproxy-deploy.sh
```

**或 clone 成個 repo：**

```bash
git clone -b one-click-deploy https://github.com/whypuss/xiaomi-tproxy.git
cd xiaomi-tproxy
```

### 2. 運行

```bash
./ax9000-tproxy-deploy.sh
```

### 3. 回答問題

```
► 路由器 IP（默認 192.168.31.1）: [直接 Enter 或輸入 IP]
► SSH 密碼: [輸入密碼]
► VLESS URL: [粘貼 vless://...]
► 代理網站: [輸入域名，逗號分隔]
► 確認部署？ [按 y]
```

---

## 腳本做了什麼

```
Step 1  — 收集路由器 IP
Step 2  — 收集 SSH 密碼
Step 3  — 收集 VLESS URL（節點）
Step 4  — 收集代理網站列表
Step 5  — 顯示部署計劃，確認
Step 6  — SSH 連接測試
Step 7  — Clone xiaomi-tproxy repo（如需要）
Step 8  — 生成 config 並上傳
Step 9  — 啟動 xray
Step 10 — 驗證 proxy 連接
```

---

## 輸出範例

```
================================================
  AX9000 xray 透明代理 一鍵部署
================================================

[✓] SSH 連接成功
[✓] Repo 已存在，跳過 clone
[✓] Config 已生成
[✓] Config 已拷入 container
[✓] xray 已啟動 (PID: 12345)
[✓] 代理連接成功！
    192.168.31.1:36332 -> 172.67.144.125:443 ESTABLISHED

================================================
  部署完成！
================================================

測試：喺 AX9000 WiFi 設備訪問 chatgpt.com
```

---

## 常見問題

### Q: 需要預裝 Docker 嗎？
A: 係，腳本假設 Docker container `openwrt` 已經運行。如果未安裝，先行 `main` 分支的 `setup.sh`。

### Q: 唔記得 VLESS URL？
A: 從你的機場帳戶頁面複製。

### Q: 想改代理網站？
A: 重新行一次腳本，或者手動編輯 `/etc/xray/config.json` 之後重啟 xray。

### Q: 想取消代理？
A: ```bash
ssh root@192.168.31.1 'iptables -t nat -F XRAY'
```

### Q: 節點失效點算？
A: 行多次腳本，輸入新節點。或者：
```bash
ssh root@192.168.31.1 'iptables -t nat -F XRAY'
# 然後重新行腳本
```

---

## 技術架構

```
WiFi client → iptables REDIRECT :443 → xray :12346
                                            ↓ SNI sniffing
                                      matched domain → VLESS proxy
                                                   other → direct
```

**代理方式:** VLESS + WebSocket + TLS
**運行環境:** Docker container `openwrt` (sulinggg/openwrt:rpi4)
**Router:** 小米 AX9000 (ARM64)

---

## 文件

| 文件 | 說明 |
|------|------|
| `ax9000-tproxy-deploy.sh` | 一鍵部署腳本（本分支） |
| `README.md` | 本文件 |
| `main` 分支 | 完整的手動部署教程 + 原始腳本 |
