#!/bin/bash
set -e

# Define colors (定义颜色)
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}==== 网络流量监控系统安装脚本 (vnStat 2.x + Postfix) - 修正版 ====${NC}"

#-----------------------------
# 1. Root Check (Root 检查)
#-----------------------------
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 运行此脚本： sudo bash $0${NC}"
    exit 1
fi

#-----------------------------
# 2. Get User Configuration (获取用户配置)
# Force interactive input from the terminal (/dev/tty)
#-----------------------------
echo -e "${GREEN}请提供以下配置信息：${NC}"
# 强制从终端 (/dev/tty) 读取输入
read -p "请输入 163 发件邮箱： " SMTP_EMAIL < /dev/tty
read -p "请输入 163 邮箱授权码： " SMTP_PASS < /dev/tty
read -p "请输入收件邮箱： " RECIPIENT_EMAIL < /dev/tty

# Simple validation (简单的空值检查)
if [[ -z "$SMTP_EMAIL" || -z "$SMTP_PASS" || -z "$RECIPIENT_EMAIL" ]]; then
    echo -e "${RED}错误：邮箱信息不能为空。请确保在交互式环境下运行脚本。${NC}"
    exit 1
fi

#-----------------------------
# 3. Install Dependencies (安装依赖)
#-----------------------------
echo -e "${GREEN}[1/6] 安装依赖组件...${NC}"
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y vnstat mailutils postfix libsasl2-modules bc jq curl

# Start vnStat service (启动 vnStat 服务)
systemctl enable vnstat
systemctl restart vnstat

#-----------------------------
# 4. Configure Postfix (配置 Postfix)
#-----------------------------
echo -e "${GREEN}[2/6] 配置 Postfix SMTP...${NC}"

# Backup config (备份配置)
[ ! -f /etc/postfix/main.cf.bak ] && cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

# Configure parameters (配置参数)
postconf -e "relayhost = [smtp.163.com]:465"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_use_tls = yes"
postconf -e "smtp_tls_wrappermode = yes"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_generic_maps = hash:/etc/postfix/generic"

# Write password file (写入密码文件)
echo "[smtp.163.com]:465 $SMTP_EMAIL:$SMTP_PASS" > /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd

# Configure sender masquerading (配置发件人伪装)
echo "root $SMTP_EMAIL" > /etc/postfix/generic
postmap /etc/postfix/generic

systemctl restart postfix

#-----------------------------
# 5. Generate Report Script (生成报告脚本)
#-----------------------------
echo -e "${GREEN}[3/6] 生成报告脚本...${NC}"
REPORT_SCRIPT="/usr/local/bin/vnstat_monthly_report.sh"

# Write configuration variables (写入变量配置)
cat > "$REPORT_SCRIPT" << EOF
#!/bin/bash
# Configuration file (配置文件)
OUTPUT_DIR="/var/log/vnstat_reports"
EMAIL_TO="$RECIPIENT_EMAIL"
EMAIL_FROM="$SMTP_EMAIL"
EOF

# Append script logic (追加脚本逻辑)
cat >> "$REPORT_SCRIPT" << 'EOF'
CURRENT_YM=$(date +"%Y-%m")
CSV_FILE="$OUTPUT_DIR/$CURRENT_YM-traffic.csv"
HTML_FILE="$OUTPUT_DIR/$CURRENT_YM-traffic.html"

mkdir -p "$OUTPUT_DIR"
echo "interface,rx_GB,tx_GB,total_GB" > "$CSV_FILE"

HTML_CONTENT="<!DOCTYPE html>
<html>
<head>
<meta charset=\"utf-8\">
<title>服务器流量报告 $CURRENT_YM</title>
<style>
body { font-family: sans-serif; background: #f4f4f4; padding: 20px; }
.container { max-width: 600px; margin: 0 auto; background: #fff; padding: 20px; border-radius: 5px; box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
h2 { color: #333; border-bottom: 2px solid #007bff; padding-bottom: 10px; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; border-radius: 5px; overflow: hidden; }
th, td { padding: 12px; border: 1px solid #e0e0e0; text-align: center; }
th { background-color: #007bff; color: white; font-weight: bold; }
tr:nth-child(even) { background-color: #f9f9f9; }
.total { background: #e8f5e9; padding: 15px; text-align: center; font-weight: bold; margin-top: 30px; color: #2e7d32; border-radius: 5px;}
.footer { text-align:center; color:#888; margin-top:20px; font-size:12px;}
</style>
</head>
<body>
<div class=\"container\">
<h2>📊 月度流量报告 ($CURRENT_YM)</h2>
<table>
<tr><th>网卡</th><th>下载</th><th>上传</th><th>总计</th></tr>"

TOTAL_BYTES_SUM=0
# Use vnstat --json 2 as recommended for vnStat 2.x
JSON_DATA=$(vnstat --json 2) 
ifaces=$(echo "$JSON_DATA" | jq -r '.interfaces[].name')

if [ -z "$ifaces" ]; then
    HTML_CONTENT+="<tr><td colspan='4'>暂无接口数据，请等待 vnstat 生成数据库。</td></tr>"
else
    for iface in $ifaces; do
        payload=$(echo "$JSON_DATA" | jq -r --arg iface "$iface" --arg ym "$CURRENT_YM" '
            .interfaces[] | select(.name == $iface) | .traffic.month[]? | select(.date.year==($ym[0:4]|tonumber) and .date.month==($ym[5:7]|tonumber))
        ')
        if [[ -n "$payload" ]]; then
            rx_bytes=$(echo "$payload" | jq -r '.rx')
            tx_bytes=$(echo "$payload" | jq -r '.tx')
            rx_bytes=${rx_bytes:-0}
            tx_bytes=${tx_bytes:-0}
            total_bytes=$(echo "$rx_bytes + $tx_bytes" | bc)
            TOTAL_BYTES_SUM=$(echo "$TOTAL_BYTES_SUM + $total_bytes" | bc)
            # Convert bytes to GB with 2 decimal places (将字节转换为GB，保留2位小数)
            rx_gb=$(echo "scale=2; $rx_bytes / 1024 / 1024 / 1024" | bc)
            tx_gb=$(echo "scale=2; $tx_bytes / 1024 / 1024 / 1024" | bc)
            total_gb=$(echo "scale=2; $total_bytes / 1024 / 1024 / 1024" | bc)
            
            echo "$iface,$rx_gb,$tx_gb,$total_gb" >> "$CSV_FILE"
            HTML_CONTENT+="<tr><td><b>$iface</b></td><td>$rx_gb GB</td><td>$tx_gb GB</td><td>$total_gb GB</td></tr>"
        fi
    done
fi

TOTAL_GB_SUM=$(echo "scale=2; $TOTAL_BYTES_SUM / 1024 / 1024 / 1024" | bc)
HTML_CONTENT+="</table>
<div class=\"total\">本月总流量：<span style=\"font-size: 1.5em;\">$TOTAL_GB_SUM GB</span></div>
<div class=\"footer\">Generated by vnStat Monitor</div>
</div>
</body>
</html>"

# 关键修正 1: 将 HTML_CONTENT 写入 HTML_FILE
# CRITICAL FIX 1: Write HTML_CONTENT to HTML_FILE
echo "$HTML_CONTENT" > "$HTML_FILE"

if command -v mail &> /dev/null; then
    # 关键修正 2: 使用 < "$HTML_FILE" 从文件读取内容作为邮件正文
    # 并使用 -a "Content-Type: text/html" 强制设置 HTML 邮件格式
    mail -a "Content-Type: text/html" \
          -a "From: Server Monitor <$EMAIL_FROM>" \
          -s "Server Traffic Report $CURRENT_YM" \
          -A "$CSV_FILE" \
          "$EMAIL_TO" < "$HTML_FILE"
    echo "邮件发送命令已执行。"
else
    echo "错误：未找到 'mail' 命令，请检查 mailutils 是否安装。"
fi
EOF

chmod +x "$REPORT_SCRIPT"

#-----------------------------
# 6. Configure Cron Job (配置 Cron 定时任务)
#-----------------------------
echo -e "${GREEN}[4/6] 配置定时任务...${NC}"
CRON_CMD="$REPORT_SCRIPT"
if crontab -l 2>/dev/null | grep -q "vnstat_monthly_report"; then
    echo "定时任务已存在，跳过。"
else
    (crontab -l 2>/dev/null; echo "5 0 1 * * $CRON_CMD") | crontab -
    echo "定时任务已添加：每月 1 日 00:05 执行"
fi

#-----------------------------
# 7. Test and Verify (测试与验证)
#-----------------------------
echo -e "${GREEN}[5/6] 等待 vnStat 初始化数据库 (5秒)...${NC}"
sleep 5
systemctl restart vnstat

echo -e "${GREEN}[6/6] 正在运行测试...${NC}"
bash "$REPORT_SCRIPT"

# Print confirmation (打印确认信息)
echo -e "${GREEN}----------------------------------------------------------${NC}"
echo "安装成功！"
echo "发件邮箱 (163): $SMTP_EMAIL"
echo "收件邮箱: $RECIPIENT_EMAIL"
echo "查看定时任务：crontab -l"
echo "手动发送测试报告：sudo bash /usr/local/bin/vnstat_monthly_report.sh"
echo -e "${GREEN}----------------------------------------------------------${NC}"
