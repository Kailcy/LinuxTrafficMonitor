#!/bin/bash
set -e

# 定义颜色
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}==== 网络流量监控系统修复版安装脚本 (vnStat 2.x + Postfix) ====${NC}"

#-----------------------------
# 1. Root 检查
#-----------------------------
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 运行此脚本： sudo bash $0${NC}"
  exit 1
fi

#-----------------------------
# 2. 获取用户配置
#-----------------------------
# 允许环境变量传入，否则交互式输入
if [ -z "$SMTP_EMAIL" ]; then read -p "请输入 163 发件邮箱 (例如 xxx@163.com)： " SMTP_EMAIL; fi
if [ -z "$SMTP_PASS" ]; then read -p "请输入 163 邮箱授权码： " SMTP_PASS; fi
if [ -z "$RECIPIENT_EMAIL" ]; then read -p "请输入收件邮箱： " RECIPIENT_EMAIL; fi

# 简单的空值检查
if [[ -z "$SMTP_EMAIL" || -z "$SMTP_PASS" || -z "$RECIPIENT_EMAIL" ]]; then
    echo -e "${RED}错误：邮箱信息不能为空。${NC}"
    exit 1
fi

#-----------------------------
# 3. 安装依赖
#-----------------------------
echo -e "${GREEN}[1/6] 安装依赖组件...${NC}"
apt update -qq
# 此处确保安装 mailutils (提供 mail 命令) 和 jq (解析 JSON)
DEBIAN_FRONTEND=noninteractive apt install -y vnstat mailutils postfix libsasl2-modules bc jq curl

# 启动 vnStat 服务 (2.x 版本不需要手动 -u，必须依赖服务运行)
systemctl enable vnstat
systemctl restart vnstat

#-----------------------------
# 4. 配置 Postfix (SMTP 发信)
#-----------------------------
echo -e "${GREEN}[2/6] 配置 Postfix SMTP...${NC}"

# 备份配置
[ ! -f /etc/postfix/main.cf.bak ] && cp /etc/postfix/main.cf /etc/postfix/main.cf.bak

# 配置参数
postconf -e "relayhost = [smtp.163.com]:465"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_use_tls = yes"
postconf -e "smtp_tls_wrappermode = yes"
postconf -e "smtp_tls_security_level = encrypt"
postconf -e "smtp_generic_maps = hash:/etc/postfix/generic"

# 写入密码文件
echo "[smtp.163.com]:465 $SMTP_EMAIL:$SMTP_PASS" > /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd

# 配置发件人伪装 (关键：防止 553 User not authorized)
echo "root $SMTP_EMAIL" > /etc/postfix/generic
postmap /etc/postfix/generic

systemctl restart postfix

#-----------------------------
# 5. 生成报告脚本 (核心修复部分)
#-----------------------------
echo -e "${GREEN}[3/6] 生成报告脚本...${NC}"
REPORT_SCRIPT="/usr/local/bin/vnstat_monthly_report.sh"

# 第一步：只写入变量配置 (避免特殊字符干扰)

#!/bin/bash
# 配置文件
OUTPUT_DIR="/var/log/vnstat_reports"
EMAIL_TO="$RECIPIENT_EMAIL"
EMAIL_FROM="$SMTP_EMAIL"
EOF

# 第二步：追加脚本逻辑
# 注意：使用 << 'EOF' (带单引号)，这样下面的 $变量 不会被安装脚本解析，而是原样写入文件
cat >> "$REPORT_SCRIPT" << 'EOF'

# 获取时间
CURRENT_YM=$(date +"%Y-%m")
CSV_FILE="$OUTPUT_DIR/$CURRENT_YM-traffic.csv"
HTML_FILE="$OUTPUT_DIR/$CURRENT_YM-traffic.html"

mkdir -p "$OUTPUT_DIR"

# 初始化 CSV
echo "interface,rx_GB,tx_GB,total_GB" > "$CSV_FILE"

# HTML 头部
HTML_CONTENT="<!DOCTYPE html>
<html>
<head>
<meta charset=\"utf-8\">
<title>服务器流量报告 $CURRENT_YM</title>
<style>
body { font-family: sans-serif; background: #f4f4f4; padding: 20px; }
.container { max-width: 600px; margin: 0 auto; background: #fff; padding: 20px; border-radius: 5px; }
table { width: 100%; border-collapse: collapse; margin-top: 20px; }
th, td { padding: 10px; border-bottom: 1px solid #ddd; text-align: center; }
th { background-color: #007bff; color: white; }
.total { background: #e8f5e9; padding: 15px; text-align: center; font-weight: bold; margin-top: 20px; color: #2e7d32;}
</style>
</head>
<body>
<div class=\"container\">
<h2>📊 月度流量报告 ($CURRENT_YM)</h2>
<table>
<tr><th>网卡</th><th>下载</th><th>上传</th><th>总计</th></tr>"

TOTAL_BYTES_SUM=0

# 获取 vnStat JSON 数据
JSON_DATA=$(vnstat --json)

# 获取所有接口名称
ifaces=$(echo "$JSON_DATA" | jq -r '.interfaces[].name')

# 检查是否有数据
if [ -z "$ifaces" ]; then
    HTML_CONTENT+="<tr><td colspan='4'>暂无接口数据，请等待 vnstat 生成数据库。</td></tr>"
else
    for iface in $ifaces; do
        # 提取当前年月的流量 (兼容 vnstat 2.x JSON 结构)
        payload=$(echo "$JSON_DATA" | jq -r --arg iface "$iface" --arg ym "$CURRENT_YM" '
            .interfaces[] | select(.name == $iface) | .traffic.month[]? | select(.date.year==($ym[0:4]|tonumber) and .date.month==($ym[5:7]|tonumber))
        ')

        if [[ -n "$payload" ]]; then
            rx_bytes=$(echo "$payload" | jq -r '.rx')
            tx_bytes=$(echo "$payload" | jq -r '.tx')
            
            # 处理 null
            rx_bytes=${rx_bytes:-0}
            tx_bytes=${tx_bytes:-0}
            
            total_bytes=$(echo "$rx_bytes + $tx_bytes" | bc)
            TOTAL_BYTES_SUM=$(echo "$TOTAL_BYTES_SUM + $total_bytes" | bc)

            # 转换为 GB
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
<div class=\"total\">
本月总流量：<span style=\"font-size: 1.5em;\">$TOTAL_GB_SUM GB</span>
</div>
<div style=\"text-align:center; color:#888; margin-top:20px; font-size:12px;\">Generated by vnStat Monitor</div>
</div>
</body>
</html>"

# 保存 HTML 用于调试
echo "$HTML_CONTENT" > "$HTML_FILE"

# 发送邮件
# 检查 mail 命令是否存在
if command -v mail &> /dev/null; then
    mail -a "Content-Type: text/html" \
         -a "From: Server Monitor <$EMAIL_FROM>" \
         -s "Server Traffic Report $CURRENT_YM" \
         -A "$CSV_FILE" \
         "$EMAIL_TO" <<< "$HTML_CONTENT"
    
    echo "邮件发送命令已执行。"
else
    echo "错误：未找到 'mail' 命令，请检查 mailutils 是否安装。"
fi
EOF

chmod +x "$REPORT_SCRIPT"

#-----------------------------
# 6. 配置 Cron 定时任务
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
# 7. 测试与验证
#-----------------------------
echo -e "${GREEN}[5/6] 等待 vnStat 初始化数据库 (5秒)...${NC}"
sleep 5 # 给 vnStat 守护进程一点时间来创建数据库

# 强制触发一次数据库写入 (针对 2.x 版本，通常不需要，但重启服务有帮助)
systemctl restart vnstat

echo -e "${GREEN}[6/6] 正在运行测试...${NC}"
bash "$REPORT_SCRIPT"

echo -e "${GREEN}==============================================================${NC}"
echo " 安装完成！"
echo " 1. 如果没有收到邮件，请检查 /var/log/mail.log"
echo " 2. 如果流量显示为 0，是因为 vnStat 刚安装，还未统计到数据。"
echo " 3. 手动测试命令： bash $REPORT_SCRIPT"
echo -e "${GREEN}==============================================================${NC}"
