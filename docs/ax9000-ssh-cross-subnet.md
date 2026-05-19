# 🚀 小米 AX9000 跨網段 SSH 遠端連線終極手把手教程

> ⚠️ **適用於：** 家中有兩部路由器（上級 ASUS 路由器 + 下級小米 AX9000）
>
> **問題症狀：** 設定好靜態路由後，一旦小米 AX9000 斷網（WAN 口無外網），SSH 連線立即遭遇 `Connection Refused` 或 `Timeout`
>
> **解決方案：** 三步驟永久解鎖，無論斷網與否都暢通

---

## 🛠️ 開工前的網絡環境假設

本教程以此 IP 配置為準，請根據你的實際網絡自行替換：

| 設備 | IP 地址 |
|------|---------|
| 上級（ASUS）路由器網段 | `192.168.1.x` |
| 你的電腦 / Mac / Agent | `192.168.1.245`（處於 1 網段） |
| 小米 AX9000 WAN 口 | `192.168.1.59`（插在上級 ASUS 身上的 IP） |
| 小米 AX9000 本地網段 | `192.168.31.x` |

---

## 🏃‍♂️ 傻瓜式操作步驟（三步搞定）

### 第一步：SSH 登入小米路由器

打開 Termux（Android）、Mac 終端機（Terminal）或 Windows PowerShell，執行：

```bash
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.59
```

> 💡 **提示：** 如果 `1.59` 連不上，把電腦切換到小米的 Wi-Fi（31 網段），改用：
> ```bash
> ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.31.1
> ```
>
> 中途詢問 `(y/n)` 時輸入 `y`，然後輸入 Root 密碼（預設：`[ROUTER_PASSWORD]`）

看到這個就是成功：

```
 -----------------------------------------------------
       Welcome to XiaoQiang!
 -----------------------------------------------------
  $$$$$$\  $$$$$$$\  $$$$$$$$\      $$\      $$\
 $$  $$\ $$  $$\ $$  _|     $$ |     $$ |     $$ |
 ...
root@XiaoQiang:~# 
```

---

### 第二步：一鍵複製貼上（直接執行，唔好郁）

成功登入後，**直接複製以下全部內容**，貼進終端機，按 Enter：

```bash
# 1. 清理可能殘留的舊設定，防止重複寫入
sed -i '/WAN SSH FIX/,/exit 0/d' /etc/rc.local
sed -i '/exit 0/d' /etc/rc.local

# 2. 寫入防斷網鎖死的開機自動執行腳本
cat << 'EOF' >> /etc/rc.local

# === WAN SSH FIX ===
# 確保外網斷開時，1 網段的設備依然能 SSH 進來
iptables -I INPUT -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.eth4.rp_filter=0

# 延時 15 秒啟動獨立 SSH 後門（不受原廠斷網機制影響）
(sleep 15 && dropbear -p 192.168.1.59:22) &

exit 0
EOF

# 3. 立即生效（免重啟）
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0
sysctl -w net.ipv4.conf.eth4.rp_filter=0
```

執行完後終端機會回到 `root@XiaoQiang:~#`，代表完成。

---

### 第三步：確認寫入成功

```bash
cat /etc/rc.local
```

滾動到底部，確認有以下內容並以 `exit 0` 結尾：

```
# === WAN SSH FIX ===
iptables -I INPUT -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT
sysctl -w net.ipv4.conf.all.rp_filter=0
...
exit 0
```

✅ 完成！現在可以測試拔掉小米的外網線（模擬斷網），然後執行：

```bash
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.59
```

你會發現 — **秒進，絕對唔會再被拒絕或超時**。

---

## 📌 為甚麼 192.168.31.1 會 Timeout？

> ⚠️ **重要提醒：** 請一律使用 `192.168.1.59` 進行 SSH 連線，**千祈唔好郁 31.1**

| 連線目標 | 結果 | 原因 |
|---------|------|------|
| `192.168.1.59` | ✅ 秒進 | Layer 2 交換機直通，ASUS 防火牆管唔到 |
| `192.168.168.31.1` | ❌ Timeout | ASUS 路由層觸發 Martian Filter，回應封包被 drop |

**根本原因：** 當你的 Mac 連線 `31.1`，流量必須經過 ASUS 路由器跨網段轉發。小米斷網時，ASUS 的環路保護（Martian Filter/DoS 防護）會在內部直接丟棄這個「來自 LAN、經路由轉發、再回到 LAN」的流量——**小米路由器根本一粒 SYN 封包都冇收到過**。

---

## 💡 原理解析（可跳過）

### 1. 防火牆開綠燈 (`iptables`)
小米原廠韌體斷網後自動啟動防火牆封鎖 WAN 口。我們在 INPUT chain 最前面加入 `192.168.1.0/24 → port 22 ACCEPT`，等於話俾防火牆知：「自己人，全部放行。」

### 2. 防止回包被截 (`sysctl rp_filter=0`)
Linux 內置 `rp_filter`（反向路徑過濾）安全警衛。斷網後路由器失去預設網關，回覆封包時警衛認為「呢條路唔對勁」直接丟垃圾筒。設為 `0` 即命令警衛閉嘴，收到就必須回。

### 3. 獨立 SSH 後門 (`dropbear`)
原廠 SSH 服務受控於心跳守護進程，斷網時常被重置。我們用 `(sleep 15 && dropbear -p 192.168.1.59:22) &` 開機 15 秒後拉起一個完全獨立、不受原廠管轄的 SSH 服務。即使官方 SSH 掛咗，秘密通道依然固若金湯。

---

## 🔧 常見問題

**Q：為什麼 SSH 到 1.59 密碼輸入正確但一直被拒？**
> 確認你喺第一步成功 login 之後，先執行曉所有指令。如果係全新登入，可能要先 `dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key` 生成 key。

**Q：重啟後發現 SSH 又斷了？**
> 檢查 `/etc/rc.local` 是否完整寫入。確認結尾有 `exit 0`，否則 rc.local 執行時可能卡住導致後面嘅命令冇執行。

**Q：可以改為用 31.1 登入嗎？**
> 可以，但必須確保 Mac 連線緊係喺小米的 Wi-Fi（192.168.31.x 網段），唔係就一定 Timeout。
