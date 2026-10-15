# 更新记录

## v1.0.0 · 2026-10-16

首个正式版本。

### 安装

在装有 x-ui / 3x-ui 的 VPS 上用 root 执行:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/wwintj/xui-xray-traffic-panel/main/xray-traffic-panel.sh)
```

也可以下载下方附件 `xray-traffic-panel.sh` 后执行 `bash xray-traffic-panel.sh`。默认账号 / 密码:`tim` / `tim`。

升级:再次运行同一条命令。卸载:在命令末尾加 `uninstall`(保留数据)或 `purge`(连数据一起删除)。

### 主要功能

- **节点总览**:自动读取 x-ui 全部入站,按在线 / 离线 / 未使用分组;显示在线 IP、连接数、累计流量、近 7 天趋势、常去网站
- **客户端 IP**:归属地、运营商、网络类型;每个 IP 的访问网站、浏览时间轴与连接明细
- **访问网站与停留时长**:常见网站自动归类,CDN 域名归入主站;纯 IP 连接自动识别所属厂商;支持导出 CSV
- **Telegram**:上线 / 下线、新 IP、疑似共享、每日日报、日志中断、存储告警等可选通知;按钮菜单查询节点和 IP
- **空间硬上限**:数据库 + 访问日志合计不超过设定值(默认 10 GB),超出自动清理最旧数据
- **体验**:浅色 / 深色 / 跟随系统,适配手机和 iPad,可添加到主屏幕;网页内修改标题、用户名、密码

### 兼容性

- Debian 10+ / Ubuntu 20.04+
- 兼容新版 Xray(25.x)不带入站标签的访问日志
