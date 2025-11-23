#!/bin/bash
set -e

# 定义颜色便于阅读
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}==== 安装网络流量监控系统（vnStat JSON版 + 163 SMTP 修正版）====${NC}"

#-----------------------------
# 1. root 与 系统检查
#-----------------------------
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 运行此脚本： sudo bash installer.sh"
  exit 1
fi

if [ ! -f /etc/debian_version ]; then
  echo "错误：此脚本仅支持 Debian/Ubuntu 系统。"
  exit 1
fi

#-----------------------------
# 2. 用户输入邮箱信息
#-----------------------------
# 允许通过环境变量预设，方便自动化
if [ -z "$SMTP_EMAIL" ]; then read -p "请输入 163 发件邮箱： " SMTP_EMAIL; fi
if [ -z "$SMTP_PASS" ]; then read -p "请输入 163 邮箱授权码： " SMTP_PASS; fi
if [ -z "$RECIPIENT_EMAIL" ]; then read -p "请输入收件邮箱： " RECIPIENT_EMAIL; fi

#-----------------------------
# 3. 安装依赖 (新增 jq)
#-----------------------------
echo -e "${GREEN}[1/6] 安装依赖：vnstat, mailutils, postfix, jq, bc...${NC}"
apt update -qq
DEBIAN_FRONTEND=noninteractive apt install -y vnstat mailutils postfix libsasl2-modules bc jq

systemctl enable vnstat
systemctl start vnstat

#-----------------------------
# 4. 配置 Postfix SMTP
#-----------------------------
echo -e "${GREEN}[2/6] 配置 Postfix...${NC}"

# 备份原有配置
cp /etc/postfix/main.cf /etc/postfix/main.cf.bak.$(date +%F)

postconf -e "relayhost = [smtp.163.com]:465"
postconf -e "smtp_sasl_auth_enable = yes"
postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
postconf -e "smtp_sasl_security_options = noanonymous"
postconf -e "smtp_use_tls = yes"
postconf -e "smtp_tls_wrappermode = yes"
postconf -e "smtp_tls_security_level = encrypt"
# 解决发信地址重写问题，防止 553 错误
postconf -e "smtp_generic_maps = hash:/etc/postfix/generic"

# 配置密码
echo "[smtp.163.com]:465 $SMTP_EMAIL:$SMTP_PASS" > /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
chmod 600 /etc/postfix/sasl_passwd

# 配置发件人映射 (强制 root 发出的邮件伪装成 SMTP_EMAIL)
echo "root $SMTP_EMAIL" > /etc/postfix/generic
postmap /etc/postfix/generic

systemctl restart postfix

#-----------------------------
# 5. 创建流量报告脚本 (使用 jq 解析)
#-----------------------------
echo -e "${GREEN}[3/6] 创建报告脚本 /usr/local/bin/vnstat_monthly_report.sh${NC}"

cat > /usr/local/bin/vnstat_monthly_report.sh << EOF
#!/bin/bash

# 环境变量
OUTPUT_DIR="/var/log/vnstat_reports"
CURRENT_YM=\$(date +"%Y-%m")
CSV_FILE="\$OUTPUT_DIR/\$CURRENT_YM-traffic.csv"
HTML_FILE="\$OUTPUT_DIR/\$CURRENT_YM-traffic.html"
EMAIL_TO="$RECIPIENT_EMAIL"
EMAIL_FROM="$SMTP_EMAIL"

mkdir -p "\$OUTPUT_DIR"

# 初始化 CSV
echo "interface,rx_GB,tx_GB,total_GB" > "\$CSV_FILE"

# HTML 头部
HTML_CONTENT="<!DOCTYPE html>
<html>
<head>
<meta charset=\"utf-8\">
<title>服务器流量报告 \$CURRENT_YM</title>
<style>
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; background: #f4f4f4; padding: 20px; color: #333; }
.container { max-width: 600px; margin: 0 auto; background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
h2 { text-align: center; color: #2c3e50; border-bottom: 2px solid #eee; padding-bottom: 10px; }
table { width: 100%; border-collapse: collapse; margin: 20px 0; }
th, td { padding: 12px; text-align: center; border-bottom: 1px solid #ddd; }
th { background-color: #007bff; color: white; }
tr:nth-child(even) { background-color: #f9f9f9; }
.total-box { background: #e8f5e9; color: #2e7d32; padding: 15px; text-align: center; font-weight: bold; border-radius: 4px; margin-top: 20px; }
.footer { margin-top: 20px; text-align: center; font-size: 12px; color: #888; }
</style>
</head>
<body>
<div class=\"container\">
<h2>📊 月度流量报告 (\$CURRENT_YM)</h2>
<table>
<tr><th>网卡</th><th>下载</th><th>上传</th><th>总计</th></tr>"

TOTAL_BYTES_SUM=0

# 使用 vnstat --json 获取精准数据
# 注意：vnstat 2.6+ JSON 结构略有不同，这里兼容处理
JSON_DATA=\$(vnstat --json)

# 获取所有接口名称
ifaces=\$(echo "\$JSON_DATA" | jq -r '.interfaces[].name')

for iface in \$ifaces; do
    # 提取当前月的 RX 和 TX (Bytes)
    # jq 逻辑：找到对应接口 -> 找到 traffic.month -> 筛选当前年月 -> 提取 rx/tx
    # 若无数据默认为 0
    
    payload=\$(echo "\$JSON_DATA" | jq -r --arg iface "\$iface" --arg ym "\$CURRENT_YM" '
        .interfaces[] | select(.name == \$iface) | .traffic.month[]? | select(.date.year==(\$ym[0:4]|tonumber) and .date.month==(\$ym[5:7]|tonumber))
    ')

    if [[ -n "\$payload" ]]; then
        rx_bytes=\$(echo "\$payload" | jq -r '.rx')
        tx_bytes=\$(echo "\$payload" | jq -r '.tx')
        
        # 这里的 rx/tx 可能是 null，转为 0
        rx_bytes=\${rx_bytes:-0}
        tx_bytes=\${tx_bytes:-0}
        
        total_bytes=\$(echo "\$rx_bytes + \$tx_bytes" | bc)
        TOTAL_BYTES_SUM=\$(echo "\$TOTAL_BYTES_SUM + \$total_bytes" | bc)

        # 字节转 GB (保留2位小数)
        rx_gb=\$(echo "scale=2; \$rx_bytes / 1024 / 1024 / 1024" | bc)
        tx_gb=\$(echo "scale=2; \$tx_bytes / 1024 / 1024 / 1024" | bc)
        total_gb=\$(echo "scale=2; \$total_bytes / 1024 / 1024 / 1024" | bc)

        echo "\$iface,\$rx_gb,\$tx_gb,\$total_gb" >> "\$CSV_FILE"
        HTML_CONTENT+="<tr><td><b>\$iface</b></td><td>\$rx_gb GB</td><td>\$tx_gb GB</td><td>\$total_gb GB</td></tr>"
    fi
done

TOTAL_GB_SUM=\$(echo "scale=2; \$TOTAL_BYTES_SUM / 1024 / 1024 / 1024" | bc)

HTML_CONTENT+="</table>
<div class=\"total-box\">
本月服务器总流量：<br><span style=\"font-size: 24px;\">\$TOTAL_GB_SUM GB</span>
</div>
<div class=\"footer\">Generated by vnStat Monitor</div>
</div>
</body>
</html>"

echo "\$HTML_CONTENT" > "\$HTML_FILE"

# 邮件发送 (指定发件人，解决 163 拦截问题)
mail -a "Content-Type: text/html" \
     -a "From: 服务器报表 <\$EMAIL_FROM>" \
     -s "服务器月度流量报告 \$CURRENT_YM" \
     -A "\$CSV_FILE" \
     "\$EMAIL_TO" <<< "\$HTML_CONTENT"
EOF

chmod +x /usr/local/bin/vnstat_monthly_report.sh

#-----------------------------
# 6. 配置 Cron (防止重复添加)
#-----------------------------
echo -e "${GREEN}[4/6] 配置定时任务...${NC}"
CRON_CMD="/usr/local/bin/vnstat_monthly_report.sh"
if crontab -l 2>/dev/null | grep -q "$CRON_CMD"; then
    echo "定时任务已存在，跳过。"
else
    (crontab -l 2>/dev/null; echo "5 0 1 * * $CRON_CMD") | crontab -
    echo "定时任务已添加：每月 1 日 00:05 执行"
fi

#-----------------------------
# 7. 测试邮件
#-----------------------------
echo -e "${GREEN}[5/6] 正在生成并发送测试邮件...${NC}"
# 首次运行可能没有当月数据，vnStat 需要一点时间初始化数据库
# 强制更新数据库
vnstat -u || true 
bash /usr/local/bin/vnstat_monthly_report.sh

echo -e "${GREEN}==============================================================${NC}"
echo " 安装完成！"
echo "  - 发件人：$SMTP_EMAIL"
echo "  - 收件人：$RECIPIENT_EMAIL"
echo "  - 脚本路径：/usr/local/bin/vnstat_monthly_report.sh"
echo -e "${GREEN}==============================================================${NC}"