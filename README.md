# 📊 Linux Server Traffic Monitor & Monthly Report
# Linux 服务器流量监控与月报系统 (vnStat + Postfix + 163 SMTP)

这是一个轻量级的 Linux 服务器流量监控脚本。它会自动安装配置 `vnStat` 进行流量统计，并每月自动生成精美的 HTML 报表（附带 CSV 数据文件），通过 163 邮箱的 SMTP 服务发送到你的指定邮箱。

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![OS](https://img.shields.io/badge/OS-Debian%20%7C%20Ubuntu-orange.svg)

## ✨ 功能特点

* **全自动安装**：一键安装依赖 (vnStat, Postfix, jq, bc) 并完成配置。
* **精准统计**：基于 `vnStat` 获取网卡流量数据 (JSON 解析，支持 GB/TB 自动换算)。
* **HTML 邮件报表**：每月自动发送包含流量表格的 HTML 邮件，手机/PC 阅读体验极佳。
* **CSV 附件**：随邮件附带 CSV 格式的详细数据，便于存档或 Excel 分析。
* **SMTP 修正**：针对 163 邮箱严格的反垃圾策略进行了头部伪装，确保邮件不被拦截。

## 🛠️ 准备工作 (必读)

在运行脚本之前，你需要准备以下三项信息：

1.  **163 发件邮箱地址**：例如 `yourname@163.com`
2.  **收件人邮箱地址**：你想把报告发给谁（可以是同一个邮箱）。
3.  **163 邮箱授权码 (重要)**：
    * **注意**：这不是你的网页登录密码！
    * **获取方法**：
        1.  登录网页版 [163 邮箱](https://mail.163.com)。
        2.  点击顶部 **“设置”** -> **“POP3/SMTP/IMAP”**。
        3.  开启 **“IMAP/SMTP服务”** 或 **“POP3/SMTP服务”**。
        4.  系统会弹出一个窗口，显示的**一串字符串**就是授权码。
        5.  *请记录下这个授权码，脚本运行中需要输入。*

## 🚀 快速安装

使用 `wget` 下载并运行脚本。请确保你拥有 root 权限。

### 方式一：标准安装（推荐）

```bash
# 1. 下载脚本 (请将下面的 URL 替换为你实际的 GitHub Raw 链接)
wget -O install_monitor.sh [https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh](https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh)

# 2. 添加执行权限
chmod +x install_monitor.sh

# 3. 运行脚本
sudo ./install_monitor.sh
````

### 方式二：一键安装

```bash
wget -qO- [https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh](https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh) | sudo bash
```

## 📝 使用说明

运行脚本后，终端会提示你输入相关信息，示例如下：

```text
请输入 163 发件邮箱： xxxxx@163.com
请输入 163 邮箱授权码： AB12CD34EF56GH78  <-- 这里填授权码，不是登录密码
请输入收件邮箱： boss@example.com
```

### 安装后的验证

安装完成后，你可以执行以下命令测试是否正常工作：

1.  **查看定时任务**：
    脚本会自动添加 Crontab，每月 1 日凌晨 00:05 发送报告。

    ```bash
    crontab -l
    # 输出应包含：5 0 1 * * /usr/local/bin/vnstat_monthly_report.sh
    ```

2.  **手动发送测试报告**：
    如果你想立即收到一封邮件看看效果，可以手动运行生成脚本：

    ```bash
    sudo bash /usr/local/bin/vnstat_monthly_report.sh
    ```

    *运行后请检查你的收件箱（如果不显示，请检查垃圾邮件箱）。*

## 📂 文件结构

  * **`/usr/local/bin/vnstat_monthly_report.sh`**: 核心逻辑脚本，用于生成报表和发送邮件。
  * **`/var/log/vnstat_reports/`**: 存放生成的 HTML 和 CSV 历史存档文件。
  * **`/etc/postfix/`**: 邮件服务配置文件。

## ⚠️ 兼容性说明

  * **支持系统**：Debian 10+, Ubuntu 20.04+ (需要 `apt` 包管理器)。
  * **依赖**：脚本会自动安装 `vnstat`, `postfix`, `mailutils`, `libsasl2-modules`, `bc`, `jq`。

## 📄 License

MIT License

```

### 使用提示

1.  **替换 URL：** 请务必将代码块中的 `https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh` 替换为你真实的 GitHub 文件地址。
2.  **Raw 地址获取方式：** 将脚本上传到 GitHub 后 -> 点击该文件 -> 点击右上角的 **"Raw"** 按钮 -> 复制浏览器地址栏的链接。
```
