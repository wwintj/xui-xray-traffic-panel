#!/usr/bin/env bash
# 数据流量分析面板 v1.0.0(配合 x-ui / 3x-ui 的 Xray 节点连接 IP 与访问网站分析)- 一键安装 / 升级脚本(Ubuntu / Debian,需要 root)
# 项目地址: https://github.com/wwintj/xui-xray-traffic-panel
#
#   安装或升级(保留原密码、端口和历史数据):   sudo bash xray-traffic-panel.sh      (运行时会询问 VPS 绑定的域名)
#   新安装默认账号 / 密码:                     tim / tim(登录后请立即在网页里修改密码)
#   跳过询问,直接指定域名(自动找证书):        sudo DOMAIN=panel.example.com bash xray-traffic-panel.sh
#   证书在特殊位置时手动指定:                  sudo DOMAIN=panel.example.com CERT_FILE=/路径/fullchain.pem KEY_FILE=/路径/key.pem bash xray-traffic-panel.sh
#   关闭 HTTPS:                                sudo DOMAIN=off bash xray-traffic-panel.sh
#   不用域名,直接 IP:端口(HTTP,不推荐):     sudo PUBLIC=1 bash xray-traffic-panel.sh
#   改回只允许本机 / SSH 隧道访问:             sudo PUBLIC=0 bash xray-traffic-panel.sh
#   指定面板最多占用的空间(默认 10GB):       sudo STORAGE_MAX_GB=10 bash xray-traffic-panel.sh
#   重置密码 / 指定端口:                       sudo ADMIN_PASS=新密码 PORT=8443 bash xray-traffic-panel.sh
#   关闭主动探测目标 IP 证书(隐私考虑):       sudo IP_PROBE=0 bash xray-traffic-panel.sh
#   卸载(保留历史数据,重装可沿用):            sudo bash xray-traffic-panel.sh uninstall
#   彻底卸载(连同全部数据一起删除):            sudo bash xray-traffic-panel.sh purge
set -euo pipefail

PANEL_VERSION="1.0.0"
APP_DIR=/opt/xray-ip-viewer
SVC=xray-ip-viewer
ENV_FILE=/etc/xray-ip-viewer.env
LOG="${XRAY_ACCESS_LOG:-/var/log/xray/access.log}"
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行: sudo bash $0"; exit 1; }

if [ "${1:-}" = "uninstall" ] || [ "${1:-}" = "purge" ]; then
  if [ "${1:-}" = "purge" ] && { [ -t 0 ] || { [ -r /dev/tty ] && (: </dev/tty) 2>/dev/null; }; }; then
    echo "将彻底删除面板及全部历史数据(连接 IP、访问记录、设置、Telegram 配置),无法恢复。"
    read -r -p "确认请输入 yes: " ANS </dev/tty || true
    [ "$ANS" = "yes" ] || { echo "已取消。"; exit 0; }
  fi
  systemctl disable --now "$SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SVC.service" "$ENV_FILE"
  systemctl daemon-reload
  rm -rf "$APP_DIR/venv" "$APP_DIR/app.py" "$APP_DIR/requirements.txt"
  if [ "${1:-}" = "purge" ]; then
    rm -rf "$APP_DIR"
    echo "已彻底卸载,面板程序和全部数据都已删除。"
  else
    echo "已卸载。历史数据保留在 $APP_DIR/data,以后重新安装会自动沿用;"
    echo "不需要的话可以运行 purge 彻底删除:bash xray-traffic-panel.sh purge"
  fi
  echo "(Xray 访问日志和它的每日轮转设置仍保留,不影响 x-ui 正常使用。)"
  exit 0
fi

# ---- 读取旧配置(升级时沿用) ----
getold() { [ -f "$ENV_FILE" ] && { grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- || true; } || true; }
OLD_PASS="$(getold ADMIN_PASS)";   OLD_USER="$(getold ADMIN_USER)"
OLD_PORT="$(getold PORT)";         OLD_HOST="$(getold HOST)"
OLD_DOMAIN="$(getold DOMAIN)"
OLD_BUDGET="$(getold STORAGE_MAX_GB)"
OLD_IPPROBE="$(getold IP_PROBE)"
OLD_SSL_CERT="$(getold SSL_CERT)"; OLD_SSL_KEY="$(getold SSL_KEY)"

# ---- 询问 VPS 绑定的域名(在耗时的安装步骤之前问完,之后就可以去忙别的) ----
can_ask() { [ -t 0 ] || { [ -r /dev/tty ] && (: </dev/tty) 2>/dev/null; }; }
guess_domain() {  # 从 x-ui 面板设置 / 面板证书里猜域名
  [ -f "$XUI_DB" ] && command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$XUI_DB" <<'PYG' 2>/dev/null || true
import re, sqlite3, subprocess, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
d = dict(c.execute("select key, value from settings where key in ('webDomain','webCertFile')").fetchall())
dom = (d.get("webDomain") or "").strip()
if not dom and d.get("webCertFile"):
    try:
        out = subprocess.run(["openssl", "x509", "-in", d["webCertFile"], "-noout", "-subject"],
                             capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"CN\s*=\s*([^,/\n]+)", out)
        dom = m.group(1).strip() if m else ""
    except Exception:
        pass
print("" if dom.startswith("*.") else dom.lower())
PYG
}
if [ -z "${DOMAIN+x}" ]; then             # 没有用 DOMAIN=... 指定时才询问
  if can_ask; then
    DEF_DOMAIN="${OLD_DOMAIN:-$(guess_domain)}"
    echo
    echo "请输入这台 VPS 绑定的域名(用来通过 HTTPS 访问查看器,会自动查找该域名的证书)"
    if [ -n "$DEF_DOMAIN" ]; then
      HINT="直接回车使用 $DEF_DOMAIN;输入 off 表示不用域名"
    else
      HINT="例如 tim.example.com;直接回车表示不用域名"
    fi
    while true; do
      IN=""
      read -r -p "  域名($HINT): " IN </dev/tty || true
      IN="$(printf '%s' "$IN" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
      IN="${IN#http://}"; IN="${IN#https://}"; IN="${IN%%/*}"; IN="${IN%%:*}"
      [ -z "$IN" ] && IN="$DEF_DOMAIN"
      case "$IN" in ""|off|-|no|n) DOMAIN="off"; break ;; esac
      if [[ "$IN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then DOMAIN="$IN"; break; fi
      echo "  格式不对,请输入类似 tim.example.com 的域名(不要带 http:// 和端口)"
    done
    if [ "$DOMAIN" != "off" ]; then
      D_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
      if [ -z "$D_IP" ]; then
        echo "  * 提示: 现在解析不到 $DOMAIN,请确认 DNS 已指向这台 VPS(不影响继续安装)"
      elif ! hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$D_IP"; then
        echo "  * 提示: $DOMAIN 解析到 $D_IP,不是本机网卡地址(若开了 Cloudflare 代理属正常)"
      fi
    fi
    echo
  fi
fi

# ---- 分给面板的空间上限(数据库 + Xray 访问日志合计,超过会自动清理最旧的数据) ----
if [ -z "${STORAGE_MAX_GB:-}" ]; then
  STORAGE_MAX_GB="${OLD_BUDGET:-10}"
  if can_ask; then
    DISK_FREE_GB="$(df -Pk "$(dirname "$APP_DIR")" 2>/dev/null | awk 'NR==2{printf "%d", $4/1048576}')"
    while true; do
      IN=""
      read -r -p "分给面板的最大空间,单位 GB(磁盘当前剩余约 ${DISK_FREE_GB:-?} GB;直接回车 = $STORAGE_MAX_GB): " IN </dev/tty || true
      IN="$(printf '%s' "$IN" | tr -d '[:space:]' | tr -d 'GgBb')"
      [ -z "$IN" ] && break
      if [[ "$IN" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk "BEGIN{exit !($IN >= 0.5)}"; then STORAGE_MAX_GB="$IN"; break; fi
      echo "  请输入不小于 0.5 的数字,例如 10"
    done
    echo
  fi
fi
if [ -n "${DISK_FREE_GB:-}" ] && awk "BEGIN{exit !($STORAGE_MAX_GB > $DISK_FREE_GB)}"; then
  echo "  * 提示: 上限 ${STORAGE_MAX_GB} GB 大于磁盘剩余空间;不用担心,磁盘剩余低于 2 GB 时也会自动清理"
fi

# 先停掉旧服务,避免端口检测把它自己当成"被占用"
systemctl stop "$SVC" 2>/dev/null || true

echo "==> [1/6] 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv iproute2 logrotate openssl >/dev/null

echo "==> [2/6] 写入程序文件"
mkdir -p "$APP_DIR/data" "$(dirname "$LOG")"
chmod 755 "$(dirname "$LOG")"
cat > "$APP_DIR/requirements.txt" <<'REQEOF'
flask>=3.0
cheroot>=10.0
REQEOF
cat > "$APP_DIR/app.py" <<'PYEOF'
#!/usr/bin/env python3
"""
Xray 连接 IP 与网站访问查看器 v4
- 自动读取 x-ui 数据库里的全部入站(端口/备注/协议/嗅探状态),总览表一次列出
- 读取 Xray access.log (含历史轮转日志自动回填),按端口与 IP 统计来源连接及访问过的全部网站
- 智能域名归类:支持主站归并(如 googlevideo/ytimg 归入 YouTube 计算真实停留时长,同时保留全部子域名明细)、网站中文识别与分类
- 停留时长双引擎计算:
  1) 基于访问时间序列的会话切片(默认间隔 5 分钟内视为同一次浏览停留,记录进入时间、离开时间、停留时长、请求数)
  2) 结合每 5 秒 ss TCP 状态采样,对长连接/单连接复用(HTTP/2、WebSocket、流媒体等)自动延续真实在线停留时长
- 支持按端口查看:网站访问排行、累计停留时长、最长单次停留、平均停留、去重活跃浏览时长、浏览时间轴轨迹、子域名与端口明细、CSV 导出
- 归属地/运营商(中国电信/联通/移动…)/网络类型(手机、宽带、机房)
- 网页登录(会话 Cookie)+ 在线修改密码;可直接用证书提供 HTTPS
"""
import csv
import gzip
import hashlib
import hmac
import io
import ipaddress
import base64
import json
import os
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import concurrent.futures
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

from flask import Flask, Response, jsonify, redirect, render_template_string, request, session

LOG_PATH = os.environ.get("XRAY_ACCESS_LOG", "/var/log/xray/access.log")
DB_PATH = os.environ.get("DB_PATH", "/opt/xray-ip-viewer/data/ips.db")
XUI_DB = os.environ.get("XUI_DB", "/etc/x-ui/x-ui.db")
HOST = os.environ.get("HOST", "127.0.0.1")
PORT = int(os.environ.get("PORT", "18088"))
ADMIN_USER = os.environ.get("ADMIN_USER", "tim")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "")
DISPLAY_TZ = timezone(timedelta(hours=float(os.environ.get("DISPLAY_TZ_HOURS", "8"))))
SSL_CERT = os.environ.get("SSL_CERT", "")
SSL_KEY = os.environ.get("SSL_KEY", "")
TLS_ON = bool(SSL_CERT and SSL_KEY and os.path.exists(SSL_CERT) and os.path.exists(SSL_KEY))
DETAIL_DAYS = int(os.environ.get("DETAIL_DAYS", "30"))      # 逐条原始连接请求(req)保留天数
SITE_DAYS = int(os.environ.get("SITE_DAYS", "90"))          # 每次网站浏览停留会话(site_sess)保留天数(网站汇总永久保留)
STORAGE_MAX_MB = int(float(os.environ.get("STORAGE_MAX_GB", "10")) * 1024)  # 分给面板的总空间(数据库 + Xray 访问日志),硬上限
MIN_FREE_MB = int(os.environ.get("MIN_FREE_MB", "2048"))    # 磁盘剩余低于这个值时,也按同样顺序清理,给系统留出空间
SITE_IDLE_GAP = int(os.environ.get("SITE_IDLE_GAP", "300")) # 同一网站两次请求间隔不超过该秒数视为同一次停留(默认 300 秒 = 5 分钟)
DATA_DIR = os.path.dirname(DB_PATH)
AUTH_FILE = os.path.join(DATA_DIR, "auth.json")
SETTINGS_FILE = os.path.join(DATA_DIR, "settings.json")
PANEL_VERSION = os.environ.get("PANEL_VERSION", "")
PROJECT_URL = "https://github.com/wwintj/xui-xray-traffic-panel"
DEFAULT_TITLE = "数据流量分析面板"
SAMPLE_SECS = 3

# 2026/10/15 00:20:11 1.2.3.4:54321 accepted tcp:example.com:443 [inbound-32990 >> direct]
# 2026/10/15 00:20:11.123456 from tcp:1.2.3.4:54321 accepted tcp:a.com:443 [inbound-32990 >> direct] email: u1
# 新版 Xray (25.x) 大量日志行不带 [入站 >> 出站] 标签,例如:
# 2026/10/15 14:41:00.920851 from 203.0.113.10:54100 accepted tcp:172.217.117.4:443
# 这类行的节点端口通过 ss 采样到的 (客户端IP, 客户端源端口) -> 本地端口 对应关系反查
LINE_RE = re.compile(
    r"^(?P<ts>\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)? "
    r"(?:from )?(?:(?:tcp|udp):)?(?P<ip>.+?):(?P<sport>\d+) accepted (?:(?P<net>tcp|udp):)?(?P<target>\S+)"
    r"(?: \[(?P<br>[^\]]*)\])?(?: email: (?P<email>\S+))?"
)
_ARROW_RE = re.compile(r"\s+(?:>>|->|==>)\s+")

def match_line(text):
    m = LINE_RE.match(text)
    if not m:
        return None
    d = m.groupdict()
    br = (d.pop("br") or "").strip()
    parts = _ARROW_RE.split(br, 1) if br else []
    if len(parts) == 2:
        d["tag"], d["out"] = parts[0].strip(), parts[1].strip()
    else:
        d["tag"], d["out"] = None, (br or None)   # 无标签,或只有出站标签
    return d
# 入站 tag 可能是 inbound-443,也可能是 inbound-1.2.3.4:443 / inbound-[::]:443(监听了具体地址时),统一取末尾端口号
TAG_PORT_RE = re.compile(r"(\d+)$")
IP_PROBE = os.environ.get("IP_PROBE", "1") != "0"   # 是否主动探测目标 IP 的 TLS 证书来识别所属网站(设为 0 关闭)

_MULTI_TLDS = set('ac.cn,ac.jp,ac.uk,co.id,co.in,co.jp,co.kr,co.nz,co.th,co.uk,co.za,com.au,com.br,com.cn,com.hk,com.mo,com.my,com.ph,com.ru,com.sg,com.tw,com.vn,edu.cn,edu.hk,edu.sg,edu.tw,go.jp,gov.cn,gov.hk,gov.sg,gov.tw,gov.uk,ne.jp,ne.kr,net.au,net.cn,net.hk,net.tw,or.jp,or.kr,org.au,org.cn,org.hk,org.ru,org.sg,org.tw,org.uk'.split(','))
_COMPANION_TO_SITE = {d: s for s, ds in {'youtube.com': 'youtu.be,googlevideo.com,ytimg.com,ggpht.com,youtube-nocookie.com,youtube.googleapis.com,youtubei.googleapis.com', 'x.com': 'twitter.com,twimg.com,t.co,periscope.tv,pscp.tv', 'chatgpt.com': 'openai.com,oaistatic.com,oaiusercontent.com', 'claude.ai': 'anthropic.com', 'instagram.com': 'cdninstagram.com', 'facebook.com': 'fbcdn.net,fb.com,fbsbx.com,messenger.com', 'whatsapp.com': 'whatsapp.net', 'threads.net': 'threads.com', 'netflix.com': 'nflxvideo.net,nflxso.net,nflximg.net,nflxext.com', 'twitch.tv': 'ttvnw.net,jtvnw.net', 'spotify.com': 'scdn.co,spotifycdn.com', 'reddit.com': 'redd.it,redditmedia.com,redditstatic.com', 'discord.com': 'discordapp.com,discordapp.net,discord.gg,discord.media', 'telegram.org': 't.me,tdesktop.com,stel.com,telegram.me,telesco.pe', 'bilibili.com': 'b23.tv,hdslb.com,bilivideo.com,bilivideo.cn,biliapi.net', 'tiktok.com': 'tiktokv.com,tiktokcdn.com,tiktokcdn-us.com,musical.ly,byteoversea.com,ibytedtos.com,ibyteimg.com,ttwstatic.com', 'douyin.com': 'douyincdn.com,snssdk.com,amemv.com', 'github.com': 'githubusercontent.com,githubassets.com,github.io', 'wikipedia.org': 'wikimedia.org,wiktionary.org,wikidata.org', 'pixiv.net': 'pximg.net', 'disneyplus.com': 'bamgrid.com,dssott.com', 'steampowered.com': 'steamstatic.com,steamcontent.com,steamcommunity.com,steamserver.net', 'weibo.com': 'sinaimg.cn,weibo.cn,weibocdn.com', 'zhihu.com': 'zhimg.com', 'xiaohongshu.com': 'xhscdn.com,xhslink.com', 'baidu.com': 'bdimg.com,bdstatic.com', 'gamer.com.tw': 'bahamut.com.tw', 'pornhub.com': 'phncdn.com', 'xvideos.com': 'xvideos-cdn.com', 'e-hentai.org': 'ehgt.org'}.items() for d in ds.split(',')}
_SITE_CATALOG = {}
for _cat, _aux, _items in [('视频流媒体', 0, 'youtube.com:YouTube|netflix.com:Netflix|bilibili.com:哔哩哔哩 (B站)|disneyplus.com:Disney+|vimeo.com:Vimeo|nicovideo.jp:Niconico|hulu.com:Hulu|hbomax.com:Max (HBO)|max.com:Max (HBO)|primevideo.com:Prime Video|abema.tv:AbemaTV|iqiyi.com:爱奇艺|youku.com:优酷|acfun.cn:AcFun'), ('短视频', 0, 'tiktok.com:TikTok|douyin.com:抖音'), ('直播流媒体', 0, 'twitch.tv:Twitch'), ('音乐流媒体', 0, 'spotify.com:Spotify'), ('体育流媒体', 0, 'dazn.com:DAZN'), ('AI 工具', 0, 'chatgpt.com:ChatGPT / OpenAI|claude.ai:Claude / Anthropic|perplexity.ai:Perplexity AI|midjourney.com:Midjourney|poe.com:Poe AI|character.ai:Character.AI|deepseek.com:DeepSeek|grok.com:Grok (xAI)|x.ai:xAI|civitai.com:Civitai|coze.com:Coze'), ('AI / 开发', 0, 'huggingface.co:Hugging Face|cursor.sh:Cursor|cursor.com:Cursor'), ('社交媒体', 0, 'x.com:X (Twitter)|instagram.com:Instagram|facebook.com:Facebook|threads.net:Threads|tumblr.com:Tumblr|bsky.app:Bluesky|mastodon.social:Mastodon|weibo.com:微博'), ('社区论坛', 0, 'reddit.com:Reddit|ptt.cc:PTT 批踢踢|lihkg.com:LIHKG 连登|tieba.baidu.com:百度贴吧'), ('图片社区', 0, 'pinterest.com:Pinterest'), ('职场社交', 0, 'linkedin.com:LinkedIn'), ('问答社区', 0, 'quora.com:Quora|zhihu.com:知乎'), ('插画社区', 0, 'pixiv.net:Pixiv'), ('动漫/游戏社区', 0, 'gamer.com.tw:巴哈姆特'), ('技术社区', 0, 'v2ex.com:V2EX|linux.do:LINUX DO'), ('主机社区', 0, 'nodeseek.com:NodeSeek|hostloc.com:全球主机交流|lowendtalk.com:LowEndTalk'), ('生活社区', 0, 'xiaohongshu.com:小红书'), ('文化社区', 0, 'douban.com:豆瓣'), ('即时通讯', 0, 'telegram.org:Telegram|whatsapp.com:WhatsApp|line.me:LINE|signal.org:Signal|skype.com:Skype|viber.com:Viber|kakao.com:KakaoTalk'), ('社区通讯', 0, 'discord.com:Discord'), ('搜索/综合', 0, 'google.com:Google|google.com.hk:Google 香港|google.co.jp:Google 日本|google.co.uk:Google 英国|google.com.tw:Google 台湾|bing.com:Bing 必应|duckduckgo.com:DuckDuckGo|yahoo.com:Yahoo|yahoo.co.jp:Yahoo! JAPAN|yandex.com:Yandex|yandex.ru:Yandex|naver.com:NAVER|baidu.com:百度'), ('开发技术', 0, 'github.com:GitHub|gitlab.com:GitLab|bitbucket.org:Bitbucket|stackoverflow.com:Stack Overflow|stackexchange.com:Stack Exchange|docker.com:Docker|docker.io:Docker Hub|npmjs.com:npm|npmjs.org:npm|pypi.org:PyPI|pythonhosted.org:PyPI Packages|vercel.com:Vercel|vercel.app:Vercel App|pages.dev:Cloudflare Pages|workers.dev:Cloudflare Workers|render.com:Render|railway.app:Railway|supabase.com:Supabase|firebase.google.com:Firebase'), ('云服务', 0, 'digitalocean.com:DigitalOcean|vultr.com:Vultr|linode.com:Linode|hetzner.com:Hetzner|oracle.com:Oracle Cloud'), ('知识百科', 0, 'wikipedia.org:维基百科|archive.org:Internet Archive'), ('博客专栏', 0, 'medium.com:Medium|substack.com:Substack'), ('新闻资讯', 0, 'nytimes.com:纽约时报 (NYT)|bbc.com:BBC News|bbc.co.uk:BBC UK|wsj.com:华尔街日报 (WSJ)|reuters.com:路透社 (Reuters)|bloomberg.com:彭博社 (Bloomberg)|ft.com:金融时报 (FT)|economist.com:经济学人|theguardian.com:卫报 (Guardian)|cnn.com:CNN|nhk.or.jp:NHK|nikkei.com:日经新闻|zaobao.com:联合早报|zaobao.com.sg:联合早报|voanews.com:VOA|rfi.fr:法广 (RFI)|dw.com:德国之声 (DW)'), ('邮箱/办公', 0, 'gmail.com:Gmail|outlook.com:Outlook|proton.me:Proton Mail|protonmail.com:Proton Mail'), ('办公协作', 0, 'notion.so:Notion|notion.site:Notion Site|slack.com:Slack|office.com:Microsoft 365 / Office'), ('视频会议', 0, 'zoom.us:Zoom'), ('设计协作', 0, 'figma.com:Figma|canva.com:Canva'), ('云盘存储', 0, 'dropbox.com:Dropbox|mega.nz:MEGA 云盘|mega.io:MEGA 云盘'), ('工具服务', 0, '1password.com:1Password|bitwarden.com:Bitwarden'), ('电商购物', 0, 'amazon.com:Amazon 美国|amazon.co.jp:Amazon 日本|amazon.co.uk:Amazon 英国|ebay.com:eBay|aliexpress.com:全球速卖通|shopee.com:Shopee 虾皮|shopee.tw:Shopee 台湾|rakuten.co.jp:日本乐天|taobao.com:淘宝|tmall.com:天猫|jd.com:京东'), ('金融支付', 0, 'paypal.com:PayPal|stripe.com:Stripe|wise.com:Wise'), ('加密金融', 0, 'binance.com:Binance 币安|okx.com:OKX 欧易|coinbase.com:Coinbase|bybit.com:Bybit|coingecko.com:CoinGecko|coinmarketcap.com:CoinMarketCap'), ('金融行情', 0, 'tradingview.com:TradingView'), ('游戏平台', 0, 'steampowered.com:Steam|epicgames.com:Epic Games|playstation.com:PlayStation|nintendo.com:Nintendo|xbox.com:Xbox|roblox.com:Roblox|ea.com:EA Games|blizzard.com:暴雪 Battle.net|battle.net:暴雪 Battle.net|riotgames.com:Riot Games|genshinimpact.com:原神国际服|hoyoverse.com:HoYoverse'), ('游戏/娱乐', 0, 'dmm.com:DMM'), ('成人/NSFW', 0, 'pornhub.com:Pornhub|xvideos.com:XVideos|xnxx.com:XNXX|javdb.com:JavDB|javbus.com:JavBus|javlibrary.com:JAVLibrary|dmm.co.jp:FANZA (DMM)|missav.com:MissAV|missav.ws:MissAV|jable.tv:Jable|spankbang.com:SpankBang|xhamster.com:xHamster|onlyfans.com:OnlyFans|chaturbate.com:Chaturbate|stripchat.com:Stripchat|e-hentai.org:E-Hentai|exhentai.org:ExHentai|nhentai.net:nhentai|hanime1.me:Hanime1|wnacg.com:绅士漫画|18comic.vip:禁漫天堂|18comic.org:禁漫天堂'), ('网络测速', 0, 'speedtest.net:Speedtest 测速|ooklaserver.net:Speedtest 测速节点|fast.com:Fast.com (Netflix测速)'), ('网络工具', 0, 'ipinfo.io:IPInfo 查询|ip.sb:IP.SB 查询|whoer.net:Whoer IP检测|ping0.cc:Ping0 IP纯净度'), ('公共服务/CDN', 1, 'gstatic.com:Google 静态资源 (gstatic)|googleapis.com:Google API 服务|googleusercontent.com:Google 用户内容缓存|1e100.net:Google 底层节点|gvt1.com:Google 更新/分发 (gvt1)|gvt2.com:Google 更新/分发 (gvt2)|ggpht.com:Google 图片缓存|cloudflare.com:Cloudflare|cloudflareclient.com:Cloudflare 客户端|cloudflare.net:Cloudflare CDN|jsdelivr.net:jsDelivr CDN|cdnjs.com:cdnjs 公共库|unpkg.com:UNPKG CDN|fastly.net:Fastly CDN|akamaized.net:Akamai CDN|akamaihd.net:Akamai HD CDN|aka.ms:Microsoft 短链|cloudfront.net:AWS CloudFront CDN|amazonaws.com:AWS 云服务|azureedge.net:Azure CDN|msecnd.net:Microsoft CDN|office.net:Microsoft Office 服务|live.com:Microsoft 账号服务|microsoft.com:Microsoft 服务|microsoftonline.com:Microsoft 登录鉴权|mzstatic.com:Apple AppStore/媒体CDN|cdn-apple.com:Apple 系统分发 CDN|aaplimg.com:Apple 图片/系统缓存'), ('广告/统计', 1, 'doubleclick.net:Google DoubleClick 广告|googlesyndication.com:Google AdSense 广告|googleadservices.com:Google 广告服务|google-analytics.com:Google Analytics 统计|googletagmanager.com:Google Tag Manager|googletagservices.com:Google 广告标签|app-measurement.com:Firebase 统计|2mdn.net:Google 广告媒体|adtrafficquality.google:Google 广告验证'), ('DNS/基础设施', 1, "cloudflare-dns.com:Cloudflare DoH DNS|apple-dns.net:Apple DoH/内部解析|digicert.com:DigiCert 证书校验(OCSP)|sectigo.com:Sectigo 证书校验|letsencrypt.org:Let's Encrypt 证书校验|lencr.org:Let's Encrypt OCSP|pki.goog:Google 证书校验|dns.google:Google 公共 DNS|one.one.one.one:Cloudflare DNS|1.1.1.1:Cloudflare DNS (1.1.1.1)|1.0.0.1:Cloudflare DNS (1.0.0.1)|8.8.8.8:Google DNS (8.8.8.8)|8.8.4.4:Google DNS (8.8.4.4)|9.9.9.9:Quad9 DNS (9.9.9.9)|223.5.5.5:阿里公共 DNS|223.6.6.6:阿里公共 DNS|119.29.29.29:腾讯 DNSPod|114.114.114.114:114 公共 DNS"), ('系统/推送', 1, 'msftconnecttest.com:Windows 联网连通性检测|msftncsi.com:Windows 网络状态检测|windowsupdate.com:Windows 系统更新|windows.com:Windows 系统服务|apple.com:Apple 官方/系统服务|icloud.com:Apple iCloud 服务')]:
    for _kv in _items.split('|'):
        _s, _, _n = _kv.partition(':')
        _SITE_CATALOG[_s.strip()] = (_n, _cat, bool(_aux))
_HOST_SPECIAL = {'gemini.google.com': ('gemini.google.com', 'Google Gemini', 'AI 工具', False), 'aistudio.google.com': ('aistudio.google.com', 'Google AI Studio', 'AI 工具', False), 'notebooklm.google.com': ('notebooklm.google.com', 'Google NotebookLM', 'AI 工具', False), 'colab.research.google.com': ('colab.research.google.com', 'Google Colab', 'AI / 开发', False), 'drive.google.com': ('drive.google.com', 'Google Drive 云盘', '云盘存储', False), 'docs.google.com': ('docs.google.com', 'Google Docs 文档', '办公协作', False), 'mail.google.com': ('mail.google.com', 'Gmail 邮箱', '邮箱/办公', False), 'translate.google.com': ('translate.google.com', 'Google 翻译', '工具服务', False), 'maps.google.com': ('maps.google.com', 'Google 地图', '工具服务', False), 'play.google.com': ('play.google.com', 'Google Play 商店', '应用商店', False), 'news.google.com': ('news.google.com', 'Google 新闻', '新闻资讯', False), 'scholar.google.com': ('scholar.google.com', 'Google 学术', '知识百科', False), 'copilot.microsoft.com': ('copilot.microsoft.com', 'Microsoft Copilot', 'AI 工具', False), 'onedrive.live.com': ('onedrive.live.com', 'Microsoft OneDrive', '云盘存储', False), 'speed.cloudflare.com': ('speed.cloudflare.com', 'Cloudflare 测速', '网络测速', False), 'connectivitycheck.gstatic.com': ('gstatic.com', 'Android 联网状态检测', '系统/推送', True), 'mtalk.google.com': ('gstatic.com', 'Google 移动推送 (FCM)', '系统/推送', True)}
_TG_NETS = [ipaddress.ip_network(x) for x in ('149.154.160.0/20','91.108.4.0/22','91.108.8.0/22','91.108.12.0/22','91.108.16.0/22','91.108.20.0/22','91.108.56.0/22','91.105.192.0/23','185.76.151.0/24')]

# ---------------------------------------------------------------- 工具
_ts_cache = ("", 0)

def fmt_ts(ts):
    """日志时间是服务器本地时间,转成北京时间显示"""
    if not ts:
        return ""
    try:
        return (datetime.strptime(ts, "%Y/%m/%d %H:%M:%S")
                .astimezone(DISPLAY_TZ).strftime("%Y-%m-%d %H:%M:%S"))
    except ValueError:
        return ts

def fmt_epoch(t):
    return datetime.fromtimestamp(t, DISPLAY_TZ).strftime("%Y-%m-%d %H:%M:%S") if t else ""

def to_epoch(ts):
    global _ts_cache
    if ts == _ts_cache[0]:
        return _ts_cache[1]
    v = int(datetime.strptime(ts, "%Y/%m/%d %H:%M:%S").timestamp())
    _ts_cache = (ts, v)
    return v

def fmt_dur_cn(s):
    s = int(s or 0)
    if s <= 0:
        return "< 1 秒 (瞬时)"
    if s < 60:
        return f"{s} 秒"
    m, r = divmod(s, 60)
    if m < 60:
        return f"{m} 分 {r:02d} 秒"
    h, m = divmod(m, 60)
    if h < 24:
        return f"{h} 小时 {m:02d} 分"
    d, h = divmod(h, 24)
    return f"{d} 天 {h} 小时"

_norm_cache = {}

def norm_ip(s):
    r = _norm_cache.get(s, 0)
    if r != 0:
        return r
    v = s.strip("[]")
    if v.lower().startswith("::ffff:"):
        v = v[7:]
    if not v or not (v[0].isdigit() or ":" in v):
        r = None                      # 明显是域名,省掉一次 IP 解析
    else:
        try:
            r = str(ipaddress.ip_address(v))
        except ValueError:
            r = None
    if len(_norm_cache) > 300000:
        _norm_cache.clear()
    _norm_cache[s] = r
    return r

def extract_root_domain(host):
    parts = host.split(".")
    if len(parts) >= 3 and ".".join(parts[-2:]) in _MULTI_TLDS:
        return ".".join(parts[-3:])
    if len(parts) >= 2:
        return ".".join(parts[-2:])
    return host

def parse_target(raw_target):
    """解析日志里的目标地址 -> (host, dst_port, site); 无效地址返回 None"""
    if not raw_target:
        return None
    h, sep, p = raw_target.rpartition(":")
    if sep and p.isdigit():
        host = h.strip("[]").lower().strip(".")
        dst_port = int(p)
    else:
        host = raw_target.strip("[]").lower().strip(".")
        dst_port = 0
    if not host or host in ("127.0.0.1", "localhost", "::1", "0.0.0.0"):
        return None
    if host in _HOST_SPECIAL:
        return host, dst_port, _HOST_SPECIAL[host][0]
    ip_str = norm_ip(host)
    if ip_str:
        try:
            ip_obj = ipaddress.ip_address(ip_str)
            if not ip_obj.is_global:
                return None
            if ip_obj.version == 4 and any(ip_obj in net for net in _TG_NETS):
                return ip_str, dst_port, "telegram.org"
        except ValueError:
            pass
        return ip_str, dst_port, ip_str
    root = extract_root_domain(host)
    site = _COMPANION_TO_SITE.get(host) or _COMPANION_TO_SITE.get(root) or root
    return host, dst_port, site

_meta_cache = {}
_meta_gen = None

def site_meta(site, sample_host="", dst_port=0):
    """site_meta 的缓存版:同一个网站的识别结果不用每次重算;IP 识别结果更新后自动失效"""
    global _meta_gen
    ipinfo_get("")                    # 顺便检查 IP 识别结果是否有更新
    if _meta_gen != _ipinfo_ts:
        _meta_cache.clear()
        _meta_gen = _ipinfo_ts
    key = (site, sample_host, dst_port)
    r = _meta_cache.get(key)
    if r is None:
        r = _site_meta_raw(site, sample_host, dst_port)
        if len(_meta_cache) > 200000:
            _meta_cache.clear()
        _meta_cache[key] = r
    return r

def _site_meta_raw(site, sample_host="", dst_port=0):
    """返回网站的 (中文名/说明, 分类, 是否为辅助CDN/系统后台域名)"""
    if site in _HOST_SPECIAL:
        _, name, cat, aux = _HOST_SPECIAL[site]
        return name, cat, aux
    if sample_host in _HOST_SPECIAL:
        _, name, cat, aux = _HOST_SPECIAL[sample_host]
        return name, cat, aux
    if site in _SITE_CATALOG:
        return _SITE_CATALOG[site]
    if dst_port == 53 or site.startswith("dns.") or "dns" in site.split(".")[0]:
        return "DNS 解析服务", "DNS/基础设施", True
    if norm_ip(site):
        if site == "5.5.5.5":
            return "客户端 UDP 连通性探测(非真实网站)", "系统/推送", True
        own = ip_owner(site)
        info = ipinfo_get(site)
        if own and not own[3]:          # 独占 IP 段(Google/Meta/Apple 等),直接确定
            return own[0], own[1], own[2]
        if info and info["cat"] != "IP直连":   # 证书/反向DNS 命中了已知网站
            return info["name"], info["cat"], False
        if own:                          # 多站共用的 CDN 段
            return own[0], own[1], own[2]
        if info:
            return info["name"], info["cat"], False
        return "IP 直接连接", "IP直连", False
    if any(k in site for k in ("cdn","static", "assets", "cache", "edge", "img", "media")):
        return "", "公共服务/CDN", True
    if any(k in site for k in ("adservice", "adsystem", "adsrv", "doubleclick", "analytics", "telemetry", "metric", "sentry")):
        return "", "广告/统计", True
    if any(k in site for k in ("ocsp", "crl.", "pki.")):
        return "", "DNS/基础设施", True
    return "", "常规网站", False

# 常见大厂 IP 段 -> (显示名, 分类, 是否辅助, 是否多站共用)
_IP_OWNERS_RAW = [
    ("Google 服务器(Google / YouTube / Gmail 等)", "搜索/综合", False, False,
     "142.250.0.0/15 172.217.0.0/16 172.253.0.0/16 216.58.192.0/19 74.125.0.0/16 173.194.0.0/16 "
     "209.85.128.0/17 108.177.0.0/17 64.233.160.0/19 216.239.32.0/19 172.110.32.0/21 "
     "2404:6800::/32 2607:f8b0::/32 2a00:1450::/32 2800:3f0::/32"),
    ("Meta 服务器(Facebook / Instagram / WhatsApp / Threads)", "社交媒体", False, False,
     "157.240.0.0/16 31.13.24.0/21 31.13.64.0/18 179.60.192.0/22 185.60.216.0/22 57.144.0.0/14 "
     "163.70.128.0/17 129.134.0.0/16 69.171.224.0/19 66.220.144.0/20 173.252.64.0/18 102.132.96.0/20 "
     "2a03:2880::/32"),
    ("X / Twitter 服务器", "社交媒体", False, False, "104.244.40.0/21 192.133.76.0/22 69.195.160.0/19 2a04:9dc0::/29"),
    ("Apple 服务(iCloud / App Store / 推送 / 时间同步)", "系统/推送", True, False, "17.0.0.0/8 2620:149::/32 2a01:b740::/32"),
    ("Netflix 服务器", "视频流媒体", False, False,
     "23.246.0.0/18 37.77.184.0/21 45.57.0.0/17 64.120.128.0/17 66.197.128.0/17 108.175.32.0/20 "
     "192.173.64.0/18 198.38.96.0/19 198.45.48.0/20 2a00:86c0::/32"),
    ("Claude (Anthropic)", "AI 工具", False, False, "160.79.104.0/21 2607:6bc0::/32"),
    ("GitHub", "开发技术", False, False, "140.82.112.0/20 185.199.108.0/22 192.30.252.0/22"),
    ("Automattic(WordPress / Gravatar / Tumblr)", "常规网站", False, False, "192.0.64.0/18"),
    ("Cloudflare CDN(多个网站共用)", "公共服务/CDN", True, True,
     "104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 162.158.0.0/15 188.114.96.0/20 141.101.64.0/18 "
     "108.162.192.0/18 190.93.240.0/20 197.234.240.0/22 198.41.128.0/17 173.245.48.0/20 103.21.244.0/22 "
     "103.22.200.0/22 103.31.4.0/22 131.0.72.0/22 1.1.1.0/24 1.0.0.0/24 2606:4700::/32"),
    ("AWS CloudFront CDN(多个网站共用)", "公共服务/CDN", True, True,
     "13.32.0.0/15 13.224.0.0/14 18.64.0.0/14 18.154.0.0/15 18.160.0.0/15 18.164.0.0/15 18.172.0.0/15 "
     "52.84.0.0/15 54.182.0.0/16 54.192.0.0/16 54.230.0.0/16 54.239.128.0/18 99.84.0.0/16 99.86.0.0/16 "
     "143.204.0.0/16 205.251.192.0/19 216.137.32.0/19 3.160.0.0/14"),
    ("Fastly CDN(多个网站共用)", "公共服务/CDN", True, True,
     "151.101.0.0/16 199.232.0.0/16 146.75.0.0/16 23.235.32.0/20 104.156.80.0/20 2a04:4e40::/32"),
]
_IP_OWNERS = []
for _n, _c, _a, _s, _nets in _IP_OWNERS_RAW:
    for _x in _nets.split():
        _IP_OWNERS.append((ipaddress.ip_network(_x), (_n, _c, _a, _s)))
_ip_owner_cache = {}

def ip_owner(ip):
    r = _ip_owner_cache.get(ip, 0)
    if r != 0:
        return r
    r = None
    try:
        a = ipaddress.ip_address(ip)
        for net, info in _IP_OWNERS:
            if a.version == net.version and a in net:
                r = info
                break
    except ValueError:
        pass
    if len(_ip_owner_cache) < 200000:
        _ip_owner_cache[ip] = r
    return r

def parse_line(d, resolver=None):
    """日志行 -> (端口, IP);不需要统计或无法判断节点的返回 None"""
    ip = norm_ip(d["ip"])
    if not ip:
        return None
    tag = d.get("tag")
    if tag:
        if tag == "api":
            return None
        port = tag_to_port(tag)
        if port == "api":
            return None
        return port, ip
    if d.get("out") == "api":
        return None
    if resolver is None:
        return None
    port = resolver.port(ip, int(d["sport"]), to_epoch(d["ts"]))
    return (port, ip) if port else None

class PortResolver:
    """
    无标签日志行 -> 节点端口。
    1) 精确:ss 采样到的连接 (客户端IP, 客户端源端口) 与日志行的来源一致,且时间吻合
    2) 近似:该客户端IP 在该时刻(或最接近的时刻)连接的节点端口
    """
    def __init__(self, con):
        self.con = con
        self.cache = {}

    def _rows(self, ip):
        r = self.cache.get(ip)
        if r is None:
            r = list(self.con.execute(
                "SELECT port, src_port, start_ts, last_ts FROM sess WHERE ip=? ORDER BY last_ts DESC LIMIT 3000", (ip,)))
            for p, fs, ls in self.con.execute("SELECT port, first_seen, last_seen FROM conn WHERE ip=?", (ip,)):
                try:
                    r.append((p, -1, to_epoch(fs), to_epoch(ls)))
                except Exception:
                    pass
            self.cache[ip] = r
        return r

    def port(self, ip, sport, t):
        rows = self._rows(ip)
        if not rows:
            return None
        slack = SAMPLE_SECS * 2 + 2
        for p, sp, s, l in rows:
            if sp == sport and s - slack <= t <= l + slack:
                return p
        best = {}
        for p, sp, s, l in rows:
            dist = 0 if s <= t <= l else min(abs(t - s), abs(t - l))
            if p not in best or dist < best[p][0]:
                best[p] = [dist, 0]
            if dist == 0:
                best[p][1] += 1
        return min(best, key=lambda p: (best[p][0], -best[p][1]))

_tag_map = (0.0, {})

def tag_to_port(tag):
    """日志里的入站标签 -> 端口。优先用 x-ui 数据库里的 tag 对照表,其次取标签末尾的端口号"""
    global _tag_map
    if time.time() - _tag_map[0] > 60:
        m = {}
        try:
            for i in xui_inbounds():
                if i.get("tag"):
                    m[i["tag"]] = i["port"]
        except Exception:
            pass
        _tag_map = (time.time(), m)
    p = _tag_map[1].get(tag)
    if p:
        return p
    mm = TAG_PORT_RE.search(tag)
    return mm.group(1) if mm else tag

def merged_duration(intervals):
    """合并重叠的时间区间 [(start, end), ...], 计算去重后的实际活跃浏览秒数"""
    valid = sorted((int(s), int(e)) for s, e in intervals if s and e and e > s)
    if not valid:
        return 0
    total = 0
    cs, ce = valid[0]
    for s, e in valid[1:]:
        if s <= ce:
            if e > ce:
                ce = e
        else:
            total += ce - cs
            cs, ce = s, e
    return total + (ce - cs)

_ASN = {
    "中国电信": {4134, 4809, 4811, 4812, 4813, 4816, 17638, 23724},
    "中国联通": {4837, 9929, 10099, 17621, 17622, 17623, 17816},
    "中国移动": {9808, 24400, 24445, 24547, 56040, 56041, 56042, 56044, 56046, 56047, 56048},
}
_RULES = [
    ("中国电信", r"chinanet|china ?telecom|ctgnet"),
    ("中国联通", r"china ?unicom|cncgroup|cnc group|unicom"),
    ("中国移动", r"china ?mobile|cmnet|cmcc"),
    ("中国铁通", r"tietong|railcom"),
    ("中国广电", r"broadnet|china broadcasting"),
    ("教育网", r"cernet|china education"),
    ("科技网", r"cstnet|chinese academy of sciences"),
    ("长城宽带/鹏博士", r"great wall|gwbn|drpeng|dr\. ?peng"),
    ("阿里云", r"alibaba|aliyun"),
    ("腾讯云", r"tencent"),
    ("华为云", r"huawei"),
]

def carrier(isp, org="", asn=""):
    """把 ip-api 返回的英文运营商归类成国内常见叫法;认不出的保持原样"""
    text = " ".join(x or "" for x in (isp, org, asn)).lower()
    m = re.match(r"as(\d+)", (asn or "").lower())
    num = int(m.group(1)) if m else None
    for name, pat in _RULES:
        if re.search(pat, text):
            return name
    if num is not None:
        for name, s in _ASN.items():
            if num in s:
                return name
    return isp or ""

def net_kind(mobile, hosting, proxy):
    """网络类型(依据 ip-api 的标记推测)"""
    if mobile is None and hosting is None and proxy is None:
        return ""
    if hosting:
        return "机房/云主机"
    if proxy:
        return "代理/VPN"
    if mobile:
        return "手机网络"
    return "宽带/固网"

def loc_str(country, region, city):
    parts = []
    for p in (country, region, city):
        if p and p not in parts:
            parts.append(p)
    return " ".join(parts)

# ---------------------------------------------------------------- 数据库
def db():
    con = sqlite3.connect(DB_PATH, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    return con

def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    con = db()
    con.executescript(
        """
        CREATE TABLE IF NOT EXISTS conn(
            port TEXT NOT NULL, ip TEXT NOT NULL,
            first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
            cnt INTEGER NOT NULL DEFAULT 0, email TEXT,
            PRIMARY KEY(port, ip)
        );
        CREATE TABLE IF NOT EXISTS geo(
            ip TEXT PRIMARY KEY,
            country TEXT, region TEXT, city TEXT, isp TEXT, ts INTEGER,
            org TEXT, asn TEXT, mobile INTEGER, hosting INTEGER, proxy INTEGER
        );
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
        CREATE TABLE IF NOT EXISTS req(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            port TEXT NOT NULL, ip TEXT NOT NULL, t INTEGER NOT NULL,
            src_port INTEGER, net TEXT, outbound TEXT,
            host TEXT, dst_port INTEGER, site TEXT, email TEXT
        );
        CREATE INDEX IF NOT EXISTS req_pit ON req(port, ip, t);
        CREATE TABLE IF NOT EXISTS sess(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            port TEXT NOT NULL, ip TEXT NOT NULL, src_port INTEGER,
            start_ts INTEGER NOT NULL, last_ts INTEGER NOT NULL,
            open INTEGER NOT NULL DEFAULT 1, approx INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS sess_pit ON sess(port, ip, start_ts);
        CREATE TABLE IF NOT EXISTS site_ip_stat(
            port TEXT NOT NULL, ip TEXT NOT NULL, site TEXT NOT NULL,
            first_ts INTEGER NOT NULL, last_ts INTEGER NOT NULL,
            req_cnt INTEGER NOT NULL DEFAULT 0,
            visit_cnt INTEGER NOT NULL DEFAULT 0,
            stay_secs INTEGER NOT NULL DEFAULT 0,
            max_stay_secs INTEGER NOT NULL DEFAULT 0,
            sample_host TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(port, ip, site)
        );
        CREATE INDEX IF NOT EXISTS idx_sis_ps ON site_ip_stat(port, site);
        CREATE INDEX IF NOT EXISTS idx_sis_pi ON site_ip_stat(port, ip);
        CREATE TABLE IF NOT EXISTS site_sub(
            port TEXT NOT NULL, site TEXT NOT NULL,
            host TEXT NOT NULL, dst_port INTEGER NOT NULL,
            net TEXT, outbound TEXT,
            first_ts INTEGER NOT NULL, last_ts INTEGER NOT NULL,
            req_cnt INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(port, site, host, dst_port)
        );
        CREATE INDEX IF NOT EXISTS idx_sub_ps ON site_sub(port, site);
        CREATE TABLE IF NOT EXISTS site_sess(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            port TEXT NOT NULL, ip TEXT NOT NULL, site TEXT NOT NULL,
            start_ts INTEGER NOT NULL, end_ts INTEGER NOT NULL,
            stay_secs INTEGER NOT NULL DEFAULT 0,
            req_cnt INTEGER NOT NULL DEFAULT 1,
            src_port INTEGER,
            hosts TEXT NOT NULL DEFAULT '',
            outbound TEXT NOT NULL DEFAULT '',
            email TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_ss_ps ON site_sess(port, site, start_ts DESC);
        DROP INDEX IF EXISTS idx_ss_pi;
        CREATE INDEX IF NOT EXISTS idx_ss_pi2 ON site_sess(port, ip, start_ts DESC, end_ts);
        DROP INDEX IF EXISTS idx_ss_p;
        CREATE INDEX IF NOT EXISTS idx_ss_p2 ON site_sess(port, start_ts DESC, end_ts);
        CREATE INDEX IF NOT EXISTS idx_ss_src ON site_sess(port, ip, src_port);
        CREATE INDEX IF NOT EXISTS idx_ss_pis ON site_sess(port, ip, site);
        CREATE TABLE IF NOT EXISTS node_seen(
            port TEXT PRIMARY KEY, remark TEXT NOT NULL DEFAULT '', protocol TEXT NOT NULL DEFAULT '',
            last_ts INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    cols = {r[1] for r in con.execute("PRAGMA table_info(geo)")}
    for c, typ in (("org", "TEXT"), ("asn", "TEXT"), ("mobile", "INTEGER"),
                   ("hosting", "INTEGER"), ("proxy", "INTEGER")):
        if c not in cols:
            con.execute(f"ALTER TABLE geo ADD COLUMN {c} {typ}")

    req_cols = {r[1] for r in con.execute("PRAGMA table_info(req)")}
    for c, typ in (("host", "TEXT"), ("dst_port", "INTEGER"), ("site", "TEXT"), ("email", "TEXT")):
        if c not in req_cols:
            con.execute(f"ALTER TABLE req ADD COLUMN {c} {typ}")
    con.execute("CREATE INDEX IF NOT EXISTS req_psit ON req(port, site, t)")
    con.execute("CREATE INDEX IF NOT EXISTS req_t ON req(t)")

    # 若从旧版(无网站统计)升级,重置 req 游标以便从现有日志中完整回填过往访问过的网站与停留时长
    con.execute(
        """CREATE TABLE IF NOT EXISTS ip_hint(
            ip TEXT PRIMARY KEY, ptr TEXT, sans TEXT, org TEXT,
            name TEXT NOT NULL DEFAULT '', cat TEXT NOT NULL DEFAULT 'IP直连',
            ts INTEGER NOT NULL DEFAULT 0)"""
    )
    sv = con.execute("SELECT v FROM meta WHERE k='site_schema_v'").fetchone()
    ver = sv[0] if sv else ""
    if ver not in ("4", "5"):
        con.execute("DELETE FROM req WHERE site IS NULL")
        con.execute("DELETE FROM meta WHERE k IN ('req_offset', 'req_inode', 'site_backfilled')")
    if ver not in ("5", "6"):
        # v5:修复旧版把 inbound-IP:端口 当成端口名写入的问题,把历史数据里的错误端口名改回真实端口
        migrate_ports(con)
    if ver != "6":
        # v6:噪音请求(UDP 探测 / DNS)不再存逐条明细,清掉以前存下的,能省下大部分空间
        con.execute("DELETE FROM req WHERE dst_port = 53 OR site = '5.5.5.5'")
        con.execute("DELETE FROM site_sess WHERE site = '5.5.5.5' OR (site IN (SELECT site FROM site_sub WHERE dst_port = 53) "
                    "AND site NOT IN (SELECT site FROM site_sub WHERE dst_port != 53))")
        con.execute("REPLACE INTO meta VALUES('site_schema_v', '6')")
    con.commit()
    # 开启增量回收:删掉的数据占用的空间会真正还给磁盘(SQLite 默认只会留着重复利用)
    try:
        if con.execute("PRAGMA auto_vacuum").fetchone()[0] != 2:
            con.execute("PRAGMA auto_vacuum = INCREMENTAL")
            con.execute("VACUUM")
    except Exception as e:  # noqa
        print("vacuum setup error:", e, file=sys.stderr)
    con.close()

def migrate_ports(con):
    tables = ("conn", "req", "sess", "site_ip_stat", "site_sub", "site_sess")
    olds = set()
    for t in tables:
        olds |= {r[0] for r in con.execute(f"SELECT DISTINCT port FROM {t}")}
    for old in olds:
        if not old or old.isdigit() or old == "api":
            continue
        new = tag_to_port(old)
        if new == old:
            continue
        for t in tables:
            con.execute(f"UPDATE OR IGNORE {t} SET port=? WHERE port=?", (new, old))
            con.execute(f"DELETE FROM {t} WHERE port=?", (old,))

# ---------------------------------------------------------------- x-ui 入站列表
def xui_inbounds():
    """读取 x-ui 里配置的全部入站:端口、备注、协议、是否启用、是否开启域名嗅探"""
    if not os.path.exists(XUI_DB):
        return []
    def _query(c):
        for sql, hs, ht in (
            ("SELECT port, remark, protocol, enable, sniffing, tag, up, down FROM inbounds ORDER BY id", True, True),
            ("SELECT port, remark, protocol, enable, sniffing, tag FROM inbounds ORDER BY id", True, True),
            ("SELECT port, remark, protocol, enable, sniffing FROM inbounds ORDER BY id", True, False),
            ("SELECT port, remark, protocol, enable FROM inbounds ORDER BY id", False, False),
        ):
            try:
                return c.execute(sql).fetchall(), hs, ht
            except Exception:
                continue
        raise RuntimeError("inbounds 表读取失败")

    try:
        con = sqlite3.connect(f"file:{XUI_DB}?mode=ro", uri=True, timeout=5)
        rows, has_sniff, has_tag = _query(con)
        con.close()
    except Exception:
        try:
            tmp = os.path.join(DATA_DIR, "xui_copy.db")
            shutil.copy(XUI_DB, tmp)
            con = sqlite3.connect(tmp)
            rows, has_sniff, has_tag = _query(con)
            con.close()
        except Exception as e:  # noqa
            print("read x-ui db error:", e, file=sys.stderr)
            return []
    out = []
    for r in rows:
        sniff_on = None
        if has_sniff and len(r) > 4 and r[4]:
            try:
                sniff_on = bool(json.loads(r[4]).get("enabled"))
            except Exception:
                sniff_on = None
        out.append({"port": str(r[0]), "remark": r[1] or "", "protocol": r[2] or "",
                    "enable": bool(r[3]), "sniffing": sniff_on,
                    "tag": (r[5] if has_tag and len(r) > 5 and r[5] else ""),
                    "up": int(r[6] or 0) if len(r) > 7 else 0,
                    "down": int(r[7] or 0) if len(r) > 7 else 0})
    return out

_ports_cache = (0.0, set())

def known_ports():
    global _ports_cache
    if time.time() - _ports_cache[0] > 60:
        ports = {i["port"] for i in xui_inbounds()}
        try:
            con = db()
            ports |= {r[0] for r in con.execute("SELECT DISTINCT port FROM conn")}
            con.close()
        except Exception:
            pass
        _ports_cache = (time.time(), ports)
    return _ports_cache[1]

# ---------------------------------------------------------------- 日志入库与网站停留计算
def read_new_lines(con, off_key, ino_key, max_raw=50000):
    """读取日志里新增的完整行。返回 (解析结果, 新offset, inode, 是否读到末尾);日志不存在返回 None"""
    try:
        st = os.stat(LOG_PATH)
    except OSError:
        return None
    meta = dict(con.execute("SELECT k, v FROM meta WHERE k IN (?,?)", (off_key, ino_key)).fetchall())
    offset = int(meta.get(off_key, 0))
    inode = int(meta.get(ino_key, 0))
    if inode != st.st_ino or st.st_size < offset:  # 日志被轮转/截断:从头读
        offset = 0
    lines, raw, eof = [], 0, True
    hold_after = time.time() - (SAMPLE_SECS + 4)   # 太新的行稍等几秒,让 ss 采样先记下这条连接,便于精确判断节点
    with open(LOG_PATH, "rb") as f:
        f.seek(offset)
        while True:
            line = f.readline()
            if not line or not line.endswith(b"\n"):
                break  # 不完整的最后一行下次再读
            d = match_line(line.decode("utf-8", "ignore"))
            if d and not d.get("tag"):
                try:
                    te = to_epoch(d["ts"])
                    if hold_after < te < time.time() + 120:
                        break
                except Exception:
                    pass
            offset += len(line)
            raw += 1
            if d:
                lines.append(d)
            if raw >= max_raw:
                eof = False
                break
    return lines, offset, st.st_ino, eof

def save_pos(con, off_key, ino_key, offset, inode):
    con.execute("REPLACE INTO meta VALUES(?, ?)", (off_key, str(offset)))
    con.execute("REPLACE INTO meta VALUES(?, ?)", (ino_key, str(inode)))

def ingest_conn(con):
    """按 (端口, IP) 汇总:首次/最近连接、次数"""
    n = 0
    while True:
        res = read_new_lines(con, "offset", "inode")
        if res is None:
            return n
        lines, offset, inode, eof = res
        agg = {}
        resolver = PortResolver(con)
        for d in lines:
            pi = parse_line(d, resolver)
            if not pi:
                continue
            ts, email = d["ts"], d["email"] or ""
            a = agg.get(pi)
            if a is None:
                agg[pi] = [ts, ts, 1, email]
            else:
                a[0], a[1] = min(a[0], ts), max(a[1], ts)
                a[2] += 1
                if email:
                    a[3] = email
            n += 1
        for (port, ip), (first, last, cnt, email) in agg.items():
            con.execute(
                """INSERT INTO conn(port, ip, first_seen, last_seen, cnt, email)
                   VALUES(?,?,?,?,?,?)
                   ON CONFLICT(port, ip) DO UPDATE SET
                     first_seen=MIN(first_seen, excluded.first_seen),
                     last_seen=MAX(last_seen, excluded.last_seen),
                     cnt=cnt+excluded.cnt,
                     email=COALESCE(NULLIF(excluded.email,''), conn.email)""",
                (port, ip, first, last, cnt, email),
            )
        save_pos(con, "offset", "inode", offset, inode)
        con.commit()
        if eof:
            return n

def _process_site_batch(con, lines, req_cutoff, site_cutoff, also_conn=True):
    """
    批量处理日志行:
    1) 写入 req 明细表 (保留 DETAIL_DAYS 天)
    2) 汇总 site_sub 子域名与目标端口表 (永久保留)
    3) 会话切片计算每次网站访问的进入时间、离开时间、停留时长 (site_sess, 保留 SITE_DAYS 天)
    4) 汇总 site_ip_stat 端口-IP-网站统计表 (永久保留)
    """
    req_rows = []
    sub_agg = {}   # (port, site, host, dst_port) -> [net, out, first_ts, last_ts, cnt]
    stat_agg = {}  # (port, ip, site) -> [first_ts, last_ts, req_cnt, visit_cnt, stay_delta, max_stay, sample_host]
    active_sess = {}  # (port, ip, site) -> dict
    new_sess_list = []
    dirty_db_sess = {}
    conn_agg = {} if also_conn else None
    resolver = PortResolver(con)

    for d in lines:
        pi = parse_line(d, resolver)
        if not pi:
            continue
        port, ip = pi
        ts = d["ts"]
        t = to_epoch(ts)
        sport = int(d["sport"])
        net = (d["net"] or "").lower()
        out = (d["out"] or "").strip()
        email = d["email"] or ""

        if also_conn:
            ca = conn_agg.get(pi)
            if ca is None:
                conn_agg[pi] = [ts, ts, 1, email]
            else:
                ca[0], ca[1] = min(ca[0], ts), max(ca[1], ts)
                ca[2] += 1
                if email:
                    ca[3] = email

        tgt = parse_target(d.get("target", ""))
        if tgt:
            host, dst_port, site = tgt
        else:
            host, dst_port, site = "", 0, ""

        # 噪音:客户端 UDP 探测 (5.5.5.5) 和 DNS 查询 (:53) 占日志的大头,只计入汇总,不存逐条明细与停留会话
        noise = site == "5.5.5.5" or dst_port == 53
        if t >= req_cutoff and not noise:
            req_rows.append((port, ip, t, sport, net, out, host, dst_port, site, email))

        if not site:
            continue

        # 1. 子域名汇总
        sk = (port, site, host, dst_port)
        sa = sub_agg.get(sk)
        if sa is None:
            sub_agg[sk] = [net, out, t, t, 1]
        else:
            if net:
                sa[0] = net
            if out:
                sa[1] = out
            if t < sa[2]:
                sa[2] = t
            if t > sa[3]:
                sa[3] = t
            sa[4] += 1

        # 2. 网站会话切片与停留时长计算
        pis = (port, ip, site)
        if pis not in active_sess:
            row = con.execute(
                "SELECT id, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound, email "
                "FROM site_sess WHERE port=? AND ip=? AND site=? ORDER BY id DESC LIMIT 1",
                pis
            ).fetchone()
            if row:
                h_list = [x for x in (row[6] or "").split(", ") if x]
                active_sess[pis] = {
                    "id": row[0], "port": port, "ip": ip, "site": site,
                    "start_ts": row[1], "end_ts": row[2], "stay_secs": row[3],
                    "req_cnt": row[4], "src_port": row[5], "hosts": h_list,
                    "outbound": row[7] or "", "email": row[8] or "",
                }
            else:
                active_sess[pis] = None

        cur = active_sess[pis]
        h_label = f"{host}:{dst_port}" if dst_port and dst_port not in (80, 443) else host
        st_entry = stat_agg.get(pis)
        if st_entry is None:
            st_entry = [t, t, 0, 0, 0, 0, h_label]
            stat_agg[pis] = st_entry
        else:
            if t < st_entry[0]:
                st_entry[0] = t
            if t > st_entry[1]:
                st_entry[1] = t
            if h_label:
                st_entry[6] = h_label
        st_entry[2] += 1  # req_cnt
        if noise:
            continue

        if cur is not None and t >= cur["start_ts"] and (t - cur["end_ts"]) <= SITE_IDLE_GAP:
            old_stay = cur["stay_secs"]
            if t > cur["end_ts"]:
                cur["end_ts"] = t
            cur["req_cnt"] += 1
            new_stay = max(cur["end_ts"] - cur["start_ts"], 1 if cur["req_cnt"] > 1 else 0)
            cur["stay_secs"] = new_stay
            cur["src_port"] = sport
            if h_label and h_label not in cur["hosts"] and len(cur["hosts"]) < 6:
                cur["hosts"].append(h_label)
            if out:
                cur["outbound"] = out
            if email:
                cur["email"] = email
            delta = new_stay - old_stay
            if delta > 0:
                st_entry[4] += delta
            if new_stay > st_entry[5]:
                st_entry[5] = new_stay
            if cur["id"] is not None:
                dirty_db_sess[cur["id"]] = cur
        else:
            # 开启一段新的网站访问停留会话
            new_s = {
                "id": None, "port": port, "ip": ip, "site": site,
                "start_ts": t, "end_ts": t, "stay_secs": 0,
                "req_cnt": 1, "src_port": sport,
                "hosts": [h_label] if h_label else [],
                "outbound": out, "email": email,
            }
            active_sess[pis] = new_s
            if t >= site_cutoff:
                new_sess_list.append(new_s)
            st_entry[3] += 1  # visit_cnt += 1

    if also_conn and conn_agg:
        for (port, ip), (first, last, cnt, email) in conn_agg.items():
            con.execute(
                """INSERT INTO conn(port, ip, first_seen, last_seen, cnt, email)
                   VALUES(?,?,?,?,?,?)
                   ON CONFLICT(port, ip) DO UPDATE SET
                     first_seen=MIN(first_seen, excluded.first_seen),
                     last_seen=MAX(last_seen, excluded.last_seen),
                     email=COALESCE(NULLIF(excluded.email,''), conn.email)""",
                (port, ip, first, last, cnt, email),
            )

    if req_rows:
        con.executemany(
            "INSERT INTO req(port,ip,t,src_port,net,outbound,host,dst_port,site,email) "
            "VALUES(?,?,?,?,?,?,?,?,?,?)",
            req_rows,
        )

    if sub_agg:
        con.executemany(
            """INSERT INTO site_sub(port,site,host,dst_port,net,outbound,first_ts,last_ts,req_cnt)
               VALUES(?,?,?,?,?,?,?,?,?)
               ON CONFLICT(port,site,host,dst_port) DO UPDATE SET
                 first_ts=MIN(first_ts, excluded.first_ts),
                 last_ts=MAX(last_ts, excluded.last_ts),
                 req_cnt=req_cnt+excluded.req_cnt,
                 net=COALESCE(NULLIF(excluded.net,''), site_sub.net),
                 outbound=COALESCE(NULLIF(excluded.outbound,''), site_sub.outbound)""",
            [(p, s, h, dp, v[0], v[1], v[2], v[3], v[4]) for (p, s, h, dp), v in sub_agg.items()],
        )

    if dirty_db_sess:
        con.executemany(
            "UPDATE site_sess SET end_ts=?, stay_secs=?, req_cnt=?, src_port=?, hosts=?, outbound=?, email=? "
            "WHERE id=?",
            [(c["end_ts"], c["stay_secs"], c["req_cnt"], c["src_port"],
              ", ".join(c["hosts"]), c["outbound"], c["email"], c["id"])
             for c in dirty_db_sess.values()],
        )

    if new_sess_list:
        con.executemany(
            "INSERT INTO site_sess(port,ip,site,start_ts,end_ts,stay_secs,req_cnt,src_port,hosts,outbound,email) "
            "VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            [(c["port"], c["ip"], c["site"], c["start_ts"], c["end_ts"], c["stay_secs"],
              c["req_cnt"], c["src_port"], ", ".join(c["hosts"]), c["outbound"], c["email"])
             for c in new_sess_list],
        )

    if stat_agg:
        con.executemany(
            """INSERT INTO site_ip_stat(port,ip,site,first_ts,last_ts,req_cnt,visit_cnt,stay_secs,max_stay_secs,sample_host)
               VALUES(?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(port,ip,site) DO UPDATE SET
                 first_ts=MIN(first_ts, excluded.first_ts),
                 last_ts=MAX(last_ts, excluded.last_ts),
                 req_cnt=req_cnt+excluded.req_cnt,
                 visit_cnt=visit_cnt+excluded.visit_cnt,
                 stay_secs=stay_secs+excluded.stay_secs,
                 max_stay_secs=MAX(max_stay_secs, excluded.max_stay_secs),
                 sample_host=COALESCE(NULLIF(excluded.sample_host,''), site_ip_stat.sample_host)""",
            [(p, i, s, v[0], v[1], v[2], v[3], v[4], v[5], v[6]) for (p, i, s), v in stat_agg.items()],
        )

def backfill_rotated_logs(con):
    """首次安装或升级 v4 时,自动扫描并回填 /var/log/xray/access.log.* 历史轮转日志中的网站访问记录"""
    done = con.execute("SELECT v FROM meta WHERE k='site_backfilled'").fetchone()
    if done and done[0] == "1":
        return
    log_dir = os.path.dirname(LOG_PATH) or "."
    base = os.path.basename(LOG_PATH)
    rotated = []
    try:
        for fn in os.listdir(log_dir):
            if fn.startswith(base + ".") and not fn.endswith(".bak"):
                full = os.path.join(log_dir, fn)
                if os.path.isfile(full):
                    rotated.append(full)
    except OSError:
        pass
    rotated.sort(key=lambda p: os.path.getmtime(p))
    req_cutoff = int(time.time() - DETAIL_DAYS * 86400)
    site_cutoff = int(time.time() - SITE_DAYS * 86400)
    for path in rotated:
        try:
            opener = gzip.open if path.endswith(".gz") else open
            batch = []
            with opener(path, "rb") as f:
                for raw_line in f:
                    d = match_line(raw_line.decode("utf-8", "ignore"))
                    if d:
                        batch.append(d)
                        if len(batch) >= 30000:
                            _process_site_batch(con, batch, req_cutoff, site_cutoff, also_conn=True)
                            con.commit()
                            batch.clear()
            if batch:
                _process_site_batch(con, batch, req_cutoff, site_cutoff, also_conn=True)
                con.commit()
        except Exception as e:  # noqa
            print(f"backfill {path} error:", e, file=sys.stderr)
    con.execute("REPLACE INTO meta VALUES('site_backfilled', '1')")
    con.execute("REPLACE INTO meta VALUES('untagged_backfilled', '1')")
    con.commit()

def _rotated_logs():
    log_dir = os.path.dirname(LOG_PATH) or "."
    base = os.path.basename(LOG_PATH)
    out = []
    try:
        for fn in os.listdir(log_dir):
            full = os.path.join(log_dir, fn)
            if fn.startswith(base + ".") and not fn.endswith(".bak") and os.path.isfile(full):
                out.append(full)
    except OSError:
        pass
    out.sort(key=lambda p: os.path.getmtime(p))
    return out

def backfill_untagged(con):
    """
    v6 升级时执行一次:旧版会丢弃不带入站标签的日志行(新版 Xray 大部分行都是这样),
    这里把历史日志(轮转日志 + 当前日志里已读过的部分)中这类行补录进来;带标签的行之前已统计,跳过以免重复。
    """
    done = con.execute("SELECT v FROM meta WHERE k='untagged_backfilled'").fetchone()
    if done and done[0] == "1":
        return
    req_cutoff = int(time.time() - DETAIL_DAYS * 86400)
    site_cutoff = int(time.time() - SITE_DAYS * 86400)
    meta = dict(con.execute("SELECT k, v FROM meta WHERE k IN ('req_offset','req_inode')").fetchall())
    cur_limit = 0
    try:
        if int(meta.get("req_inode", 0)) == os.stat(LOG_PATH).st_ino:
            cur_limit = int(meta.get("req_offset", 0))
    except (OSError, ValueError):
        pass
    sources = [(p, None) for p in _rotated_logs()] + ([(LOG_PATH, cur_limit)] if cur_limit else [])
    for path, limit in sources:
        try:
            opener = gzip.open if path.endswith(".gz") else open
            batch, pos = [], 0
            with opener(path, "rb") as f:
                for raw_line in f:
                    pos += len(raw_line)
                    if limit is not None and pos > limit:
                        break
                    d = match_line(raw_line.decode("utf-8", "ignore"))
                    if d and not d.get("tag"):
                        batch.append(d)
                        if len(batch) >= 30000:
                            _process_site_batch(con, batch, req_cutoff, site_cutoff, also_conn=True)
                            con.commit()
                            batch.clear()
            if batch:
                _process_site_batch(con, batch, req_cutoff, site_cutoff, also_conn=True)
                con.commit()
        except Exception as e:  # noqa
            print(f"backfill untagged {path} error:", e, file=sys.stderr)
    con.execute("REPLACE INTO meta VALUES('untagged_backfilled', '1')")
    con.commit()

def ingest_req(con):
    """每次连接请求及网站访问停留统计入库"""
    backfill_rotated_logs(con)
    backfill_untagged(con)
    req_cutoff =int(time.time() - DETAIL_DAYS * 86400)
    site_cutoff = int(time.time() - SITE_DAYS * 86400)
    while True:
        res = read_new_lines(con, "req_offset", "req_inode")
        if res is None:
            return
        lines, offset, inode, eof = res
        if lines:
            _process_site_batch(con, lines, req_cutoff, site_cutoff, also_conn=False)
        save_pos(con, "req_offset", "req_inode", offset, inode)
        con.commit()
        if eof:
            return

def ingest_once():
    con = db()
    try:
        n = ingest_conn(con)
        ingest_req(con)
        return n
    finally:
        con.close()

def db_used_bytes(con):
    pc = con.execute("PRAGMA page_count").fetchone()[0]
    fl = con.execute("PRAGMA freelist_count").fetchone()[0]
    ps = con.execute("PRAGMA page_size").fetchone()[0]
    return (pc - fl) * ps

def disk_free_bytes():
    try:
        return shutil.disk_usage(DATA_DIR).free
    except OSError:
        return 1 << 62

def _log_files():
    """Xray 访问日志及其轮转文件 -> [(路径, 大小, 修改时间)],按从旧到新排序"""
    d = os.path.dirname(LOG_PATH) or "."
    base = os.path.basename(LOG_PATH)
    out = []
    try:
        for fn in os.listdir(d):
            if fn == base or fn.startswith(base + "."):
                fp = os.path.join(d, fn)
                try:
                    st = os.stat(fp)
                    out.append((fp, st.st_size, st.st_mtime))
                except OSError:
                    pass
    except OSError:
        pass
    out.sort(key=lambda x: (x[0] == LOG_PATH, x[2]))
    return out

def db_file_bytes():
    total = 0
    for suf in ("", "-wal", "-shm"):
        try:
            total += os.path.getsize(DB_PATH + suf)
        except OSError:
            pass
    return total

def storage_usage():
    logs = sum(s for _p, s, _m in _log_files())
    dbb = db_file_bytes()
    return dbb, logs

def _shrink(con):
    try:
        con.execute("PRAGMA incremental_vacuum").fetchall()
        con.commit()
        con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchall()
    except Exception:
        pass

def prune(retention=True):
    """
    1) 按保留天数删除过期明细(retention=True 时)
    2) 硬上限:面板总占用(数据库 + 访问日志)超过 STORAGE_MAX_GB,或磁盘剩余低于 MIN_FREE_MB 时,依次:
       a. 删除已经读完的旧轮转日志;当前日志已全部读完且仍超额时清空它(Xray 是追加写入,清空是安全的)
       b. 从最旧的一天开始逐日删逐条明细(最少留最近 1 天)
       c. 仍然超额,就删除最久没出现的客户端 IP 的汇总数据,直到降到上限以内
    """
    now = int(time.time())
    budget = STORAGE_MAX_MB * 1024 * 1024
    min_free = MIN_FREE_MB * 1024 * 1024
    con = db()
    if retention:
        req_cutoff = now - DETAIL_DAYS * 86400
        site_cutoff = now - SITE_DAYS * 86400
        con.execute("DELETE FROM req WHERE t < ?", (req_cutoff,))
        con.execute("DELETE FROM sess WHERE last_ts < ? AND open = 0", (req_cutoff,))
        con.execute("DELETE FROM site_sess WHERE end_ts < ?", (site_cutoff,))
        con.commit()
        _shrink(con)

    def over():
        dbb, logs = storage_usage()
        return dbb + logs > budget or disk_free_bytes() < min_free

    actions = []
    # a. 日志:日志最多占总额度的 20%(至少 256MB);整体超额时先删旧日志
    if over() or sum(s for _p, s, _m in _log_files()) > max(budget // 5, 256 << 20):
        log_cap = max(budget // 5, 256 << 20)
        files = _log_files()
        total_logs = sum(s for _p, s, _m in files)
        for fp, size, _m in files:
            if fp == LOG_PATH:
                continue
            if total_logs <= log_cap and not over():
                break
            try:
                os.remove(fp)
                total_logs -= size
                actions.append("删除旧日志 " + os.path.basename(fp))
            except OSError:
                pass
        try:
            st = os.stat(LOG_PATH)
            meta = dict(con.execute("SELECT k, v FROM meta WHERE k IN ('offset','req_offset','inode','req_inode')").fetchall())
            consumed = (int(meta.get("offset", 0)) >= st.st_size and int(meta.get("req_offset", 0)) >= st.st_size
                        and str(st.st_ino) == meta.get("inode") == meta.get("req_inode"))
            if st.st_size > 0 and consumed and (total_logs > log_cap or over()):
                with open(LOG_PATH, "r+b") as f:
                    f.truncate(0)
                actions.append("清空已读完的访问日志")
        except (OSError, ValueError):
            pass

    # b. 逐日删最旧的明细
    days = 0
    for _ in range(400):
        if not over():
            break
        oldest = min([x for x in (
            con.execute("SELECT MIN(t) FROM req").fetchone()[0],
            con.execute("SELECT MIN(start_ts) FROM sess WHERE open = 0").fetchone()[0],
            con.execute("SELECT MIN(start_ts) FROM site_sess").fetchone()[0],
        ) if x] or [now])
        cut = oldest + 86400
        if cut > now - 86400:
            break
        con.execute("DELETE FROM req WHERE t < ?", (cut,))
        con.execute("DELETE FROM sess WHERE last_ts < ? AND open = 0", (cut,))
        con.execute("DELETE FROM site_sess WHERE end_ts < ?", (cut,))
        con.commit()
        _shrink(con)
        days += 1
    if days:
        actions.append(f"删除最旧的 {days} 天明细")

    # c. 还超额:删除最久没出现的客户端 IP 的汇总(每轮 200 个)
    ips = 0
    for _ in range(1000):
        if not over():
            break
        rows = con.execute("SELECT port, ip FROM conn ORDER BY last_seen ASC LIMIT 200").fetchall()
        if not rows:
            # 连 IP 汇总都没了,最后清最近 1 天的明细与子域名汇总
            con.execute("DELETE FROM req"); con.execute("DELETE FROM site_sess")
            con.execute("DELETE FROM sess WHERE open = 0"); con.execute("DELETE FROM site_sub")
            con.commit(); _shrink(con)
            actions.append("清空全部明细")
            break
        for port, ip in rows:
            for tb in ("conn", "site_ip_stat", "req", "site_sess", "sess"):
                con.execute(f"DELETE FROM {tb} WHERE port = ? AND ip = ?", (port, ip))
        con.execute("DELETE FROM site_sub WHERE NOT EXISTS (SELECT 1 FROM site_ip_stat s WHERE s.port = site_sub.port AND s.site = site_sub.site)")
        con.commit()
        _shrink(con)
        ips += len(rows)
    if ips:
        actions.append(f"删除 {ips} 个最久未出现 IP 的汇总")

    con.execute("REPLACE INTO meta VALUES('last_prune', ?)", (str(now),))
    if actions:
        con.execute("REPLACE INTO meta VALUES('last_trim', ?)", (f"{now}|" + ";".join(actions),))
        print("storage:", "; ".join(actions), file=sys.stderr)
    con.commit()
    con.close()

def ingest_worker():
    last_prune = last_check = 0
    while True:
        try:
            ingest_once()
            if time.time() - last_prune > 3600:
                prune(retention=True)
                last_prune = last_check = time.time()
            elif time.time() - last_check > 300:
                # 每 5 分钟看一眼空间:只是读几个文件大小,不碰数据库;真超了才去清理
                last_check = time.time()
                dbb, logs = storage_usage()
                if (dbb + logs > STORAGE_MAX_MB * 1024 * 1024
                        or disk_free_bytes() < MIN_FREE_MB * 1024 * 1024
                        or logs > max(STORAGE_MAX_MB * 1024 * 1024 // 5, 256 << 20)):
                    prune(retention=False)
        except Exception as e:  # noqa
            print("ingest error:", e, file=sys.stderr)
        time.sleep(5)

# ---------------------------------------------------------------- 当前在线 + 会话采样
def parse_ss_full(text):
    """`ss -tnH state established` -> [(本地端口, 对端IP, 对端端口)]"""
    out = []
    for line in text.splitlines():
        cols = line.split()
        if len(cols) < 2:
            continue
        lport = cols[-2].rsplit(":", 1)[-1]
        host, _, pport = cols[-1].rpartition(":")
        ip = norm_ip(host)
        if ip and lport.isdigit() and pport.isdigit():
            out.append((lport, ip, int(pport)))
    return out

def parse_ss(text):
    """-> {本地端口: {对端IP: 连接数}}"""
    m = {}
    for lport, ip, _pp in parse_ss_full(text):
        d = m.setdefault(lport, {})
        d[ip] = d.get(ip, 0) + 1
    return m

def run_ss():
    try:
        return subprocess.run(["ss", "-tnH", "state", "established"],
                              capture_output=True, text=True, timeout=5).stdout
    except Exception:
        return ""

def live_map():
    return parse_ss(run_ss())

def sampler_step(con, opened, text, ports, now, first_round=False):
    """
    用一次 ss 快照更新会话:
    1) 新连接开一条 sess 记录,消失的连接标记结束,其余刷新最后在线时间
    2) 若某条活跃 TCP 连接 (port, ip, src_port) 对应唯一一个近期网站会话 (如 HTTP/2 长连接、流媒体、WebSocket),
       则同步延长该网站的停留时长 (site_sess 与 site_ip_stat)
    """
    cur = {(lp, ip, pp) for lp, ip, pp in parse_ss_full(text) if lp in ports}
    touch = []
    for k in cur:
        if k in opened:
            touch.append((now, opened[k]))
        else:
            c = con.execute(
                "INSERT INTO sess(port,ip,src_port,start_ts,last_ts,open,approx) VALUES(?,?,?,?,?,1,?)",
                (k[0], k[1], k[2], now, now, 1 if first_round else 0))
            opened[k] = c.lastrowid
        # 同步延长单站点长连接的网站停留时长
        lp, ip, pp = k
        rows = con.execute(
            "SELECT id, site, start_ts, end_ts, stay_secs FROM site_sess "
            "WHERE port=? AND ip=? AND src_port=? AND end_ts >= ? ORDER BY id DESC LIMIT 2",
            (lp, ip, pp, now - SITE_IDLE_GAP),
        ).fetchall()
        if len(rows) == 1:
            sid, site, s_start, s_end, old_stay = rows[0]
            if now > s_end:
                new_stay = max(now - s_start, old_stay)
                delta = new_stay - old_stay
                con.execute(
                    "UPDATE site_sess SET end_ts=?, stay_secs=? WHERE id=?",
                    (now, new_stay, sid),
                )
                if delta > 0:
                    con.execute(
                        "UPDATE site_ip_stat SET last_ts=MAX(last_ts, ?), stay_secs=stay_secs+?, "
                        "max_stay_secs=MAX(max_stay_secs, ?) WHERE port=? AND ip=? AND site=?",
                        (now, delta, new_stay, lp, ip, site),
                    )
    if touch:
        con.executemany("UPDATE sess SET last_ts=? WHERE id=?", touch)
    for k in [k for k in opened if k not in cur]:
        con.execute("UPDATE sess SET open=0 WHERE id=?", (opened.pop(k),))
    con.commit()

def sampler_worker():
    opened, first = {}, True
    try:
        con = db()
        con.execute("UPDATE sess SET open=0 WHERE open=1")  # 上次运行遗留的
        con.commit()
        con.close()
    except Exception as e:  # noqa
        print("sampler init error:", e, file=sys.stderr)
    while True:
        try:
            con = db()
            sampler_step(con, opened, run_ss(), known_ports(), int(time.time()), first)
            con.close()
            first = False
        except Exception as e:  # noqa
            print("sampler error:", e, file=sys.stderr)
        time.sleep(SAMPLE_SECS)

# ---------------------------------------------------------------- 归属地
GEO_SQL = ("INSERT OR REPLACE INTO geo(ip,country,region,city,isp,ts,org,asn,mobile,hosting,proxy) "
           "VALUES(?,?,?,?,?,?,?,?,?,?,?)")

def geo_lookup(con, ips):
    public = []
    now = int(time.time())
    for ip in ips:
        if ipaddress.ip_address(ip).is_global:
            public.append(ip)
        else:
            con.execute(GEO_SQL, (ip, "内网/本机", "", "", "", now, "", "", 0, 0, 0))
    if public:
        url = ("http://ip-api.com/batch?lang=zh-CN&fields="
               "status,message,country,regionName,city,isp,org,as,mobile,proxy,hosting,query")
        req = urllib.request.Request(
            url, data=json.dumps(public).encode(),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            for d in json.load(r):
                ip = d.get("query")
                if not ip:
                    continue
                if d.get("status") == "success":
                    row = (ip, d.get("country", ""), d.get("regionName", ""), d.get("city", ""),
                           d.get("isp", ""), now, d.get("org", ""), d.get("as", ""),
                           int(bool(d.get("mobile"))), int(bool(d.get("hosting"))),
                           int(bool(d.get("proxy"))))
                else:
                    row = (ip, "未知", "", "", "", now, "", "", 0, 0, 0)
                con.execute(GEO_SQL, row)
    con.commit()

# ---------------------------------------------------------------- 目标 IP 所属网站识别
# 日志里有时只有 IP(没开嗅探、QUIC/UDP、客户端自己解析了域名)。这里通过三种线索猜出它属于哪个网站:
#   1) 反向 DNS (PTR)   2) 该 IP 443 端口 TLS 证书里的域名 (SAN/CN)   3) ip-api 的 ASN 组织名(如 Google LLC)
_ipinfo = {}
_ipinfo_ts = 0.0
_ipinfo_lock = threading.Lock()

def ipinfo_get(ip):
    """-> {"name": 显示名, "cat": 分类} 或 None(缓存 30 秒)"""
    global _ipinfo, _ipinfo_ts
    now = time.time()
    if now - _ipinfo_ts > 30:
        with _ipinfo_lock:
            if now - _ipinfo_ts > 30:
                try:
                    con = db()
                    _ipinfo = {r[0]: {"name": r[1], "cat": r[2]} for r in con.execute(
                        "SELECT ip, name, cat FROM ip_hint WHERE name != ''")}
                    con.close()
                except Exception:
                    pass
                _ipinfo_ts = time.time()
    return _ipinfo.get(ip)

def classify_names(names):
    """候选域名 -> (显示名, 分类, 命中的域名, 是否命中已知网站目录);没有可用域名返回 None"""
    cands = []
    for h in names:
        h = (h or "").lower().strip().strip(".")
        if h.startswith("*."):
            h = h[2:]
        if not h or "." not in h or norm_ip(h):
            continue
        cands.append(h)
    aux_hit = None
    for h in cands:
        if h in _HOST_SPECIAL:
            _s, n, c, aux = _HOST_SPECIAL[h]
            if not aux:
                return n, c, h, True
            aux_hit = aux_hit or (n, c, h, True)
            continue
        root = extract_root_domain(h)
        site = _COMPANION_TO_SITE.get(h) or _COMPANION_TO_SITE.get(root) or root
        if site in _SITE_CATALOG:
            n, c, aux = _SITE_CATALOG[site]
            if not aux:
                return n, c, h, True
            aux_hit = aux_hit or (n, c, h, True)
    if aux_hit:
        return aux_hit
    if cands:
        return "", "IP直连", extract_root_domain(cands[0]), False
    return None

def probe_ptr(ip):
    try:
        return socket.gethostbyaddr(ip)[0]
    except Exception:
        return ""

def probe_cert_names(ip):
    """连接 ip:443 读取 TLS 证书里的域名(不带 SNI,拿到的是默认证书)"""
    addr = f"[{ip}]:443" if ":" in ip else f"{ip}:443"
    try:
        p = subprocess.run(["openssl", "s_client", "-connect", addr],
                           input=b"", capture_output=True, timeout=8)
        m = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", p.stdout, re.S)
        if not m:
            return []
        x = subprocess.run(["openssl", "x509", "-noout", "-subject", "-ext", "subjectAltName"],
                           input=m.group(0), capture_output=True, timeout=5)
        out = x.stdout.decode("utf-8", "ignore")
        names = re.findall(r"DNS:([^,\s]+)", out)
        cn = re.search(r"CN\s*=\s*([^,\n/]+)", out)
        if cn:
            names.append(cn.group(1).strip())
        return names[:30]
    except Exception:
        return []

def fetch_orgs(ips):
    """ip-api 批量查询 ASN 组织名 -> {ip: org}"""
    try:
        req = urllib.request.Request(
            "http://ip-api.com/batch?lang=en&fields=status,org,isp,query",
            data=json.dumps(ips).encode(), headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return {d["query"]: (d.get("org") or d.get("isp") or "")
                    for d in json.load(r) if d.get("status") == "success" and d.get("query")}
    except Exception as e:  # noqa
        print("ip org lookup error:", e, file=sys.stderr)
        return {}

def ipname_worker():
    while True:
        wait = 60
        try:
            con = db()
            rows = con.execute(
                "SELECT s.site FROM site_ip_stat s LEFT JOIN ip_hint h ON h.ip = s.site "
                "WHERE (h.ip IS NULL OR (h.name = '' AND h.ts < ?)) "
                "AND (s.site GLOB '[0-9]*.[0-9]*.[0-9]*.[0-9]*' OR s.site LIKE '%:%') "
                "GROUP BY s.site ORDER BY MAX(s.last_ts) DESC LIMIT 20",
                (int(time.time()) - 7 * 86400,)).fetchall()
            ips = []
            for (s,) in rows:
                n = norm_ip(s)
                if n and ipaddress.ip_address(n).is_global:
                    ips.append(n)
            if ips:
                wait = 15
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
                    ptr_f = {ip: ex.submit(probe_ptr, ip) for ip in ips}
                    cert_f = {ip: ex.submit(probe_cert_names, ip) for ip in ips} if IP_PROBE else {}
                    ptrs, certs = {}, {}
                    for ip in ips:
                        try:
                            ptrs[ip] = ptr_f[ip].result(timeout=10)
                        except Exception:
                            ptrs[ip] = ""
                        try:
                            certs[ip] = cert_f[ip].result(timeout=15) if ip in cert_f else []
                        except Exception:
                            certs[ip] = []
                orgs = fetch_orgs(ips)
                now = int(time.time())
                for ip in ips:
                    ptr, sans, org = ptrs.get(ip, ""), certs.get(ip, []), orgs.get(ip, "")
                    cls = classify_names(sans + [ptr])   # 证书域名优先,PTR 其次
                    name, cat = "", "IP直连"
                    if cls and cls[3]:
                        name, cat = f"疑似 {cls[0]} · {cls[2]}", cls[1]
                    elif cls:
                        name = " · ".join(x for x in (org, cls[2]) if x)
                    elif org:
                        name = org
                    con.execute("REPLACE INTO ip_hint(ip,ptr,sans,org,name,cat,ts) VALUES(?,?,?,?,?,?,?)",
                                (ip, ptr, ", ".join(sans), org, name, cat, now))
                con.commit()
                global _ipinfo_ts
                _ipinfo_ts = 0.0   # 让缓存立刻刷新
            con.close()
        except Exception as e:  # noqa
            print("ipname error:", e, file=sys.stderr)
        time.sleep(wait)

def geo_worker():
    while True:
        wait = 15
        try:
            con = db()
            ips = [r[0] for r in con.execute(
                "SELECT DISTINCT ip FROM conn "
                "WHERE ip NOT IN (SELECT ip FROM geo WHERE mobile IS NOT NULL) LIMIT 100")]
            if ips:
                geo_lookup(con, ips)
                wait = 6  # ip-api 免费版限速:每分钟 15 次批量请求
            con.close()
        except Exception as e:  # noqa
            print("geo error:", e, file=sys.stderr)
            wait = 60
        time.sleep(wait)

def geo_info(con, ip):
    r = con.execute("SELECT country, region, city, isp, org, asn, mobile, hosting, proxy FROM geo WHERE ip=?",
                    (ip,)).fetchone()
    if not r:
        return {"loc": "查询中…", "carrier": "", "isp_raw": "", "net": ""}
    return {"loc": loc_str(*r[:3]), "carrier": carrier(r[3], r[4], r[5]),
            "isp_raw": r[3] or "", "net": net_kind(r[6], r[7], r[8])}

# ---------------------------------------------------------------- 账号 / 密码
def _hash(pw, salt, it):
    return hashlib.pbkdf2_hmac("sha256", pw.encode(), salt, it).hex()

def load_auth():
    try:
        with open(AUTH_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

def current_user():
    a = load_auth()
    return a["user"] if a else ADMIN_USER

def check_credentials(user, pw):
    a = load_auth()
    if a:
        calc = _hash(pw, bytes.fromhex(a["salt"]), a["iter"])
        return (hmac.compare_digest(user.encode(), a["user"].encode())
                and hmac.compare_digest(calc.encode(), a["hash"].encode()))
    return (hmac.compare_digest(user.encode(), ADMIN_USER.encode())
            and hmac.compare_digest(pw.encode(), ADMIN_PASS.encode()))

def pw_fingerprint():
    """密码一变,这个值就变,旧登录状态随之失效"""
    a = load_auth()
    return a["hash"][:16] if a else hashlib.sha256(("env:" + ADMIN_PASS).encode()).hexdigest()[:16]

def save_password(user, new_pw):
    salt, it = secrets.token_bytes(16), 200_000
    data = {"user": user, "salt": salt.hex(), "iter": it, "hash": _hash(new_pw, salt, it)}
    tmp = AUTH_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, AUTH_FILE)

def load_settings():
    try:
        with open(SETTINGS_FILE) as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}

def save_settings(d):
    tmp = SETTINGS_FILE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)   # 里面有 Telegram Bot Token,只给 root 读
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, ensure_ascii=False)
    os.replace(tmp, SETTINGS_FILE)

def site_title():
    return (load_settings().get("title") or "").strip() or DEFAULT_TITLE

def secret_key():
    p = os.path.join(DATA_DIR, "secret.key")
    try:
        with open(p) as f:
            k = f.read().strip()
            if len(k) >= 32:
                return k
    except OSError:
        pass
    k = secrets.token_hex(32)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(k)
    return k

# ---------------------------------------------------------------- Web 与接口
app = Flask(__name__)
app.config.update(
    SESSION_COOKIE_NAME="ipv_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    SESSION_COOKIE_SECURE=TLS_ON,
    PERMANENT_SESSION_LIFETIME=timedelta(days=7),
)
_FAILS = {}
_LOCK = threading.Lock()
MAX_FAILS, WINDOW = 8, 600

def blocked(ip):
    now = time.time()
    with _LOCK:
        n, t0 = _FAILS.get(ip, (0, now))
        if now - t0 > WINDOW:
            _FAILS.pop(ip, None)
            return False
        return n >= MAX_FAILS

def note_fail(ip):
    now = time.time()
    with _LOCK:
        n, t0 = _FAILS.get(ip, (0, now))
        if now - t0 > WINDOW:
            n, t0 = 0, now
        _FAILS[ip] = (n + 1, t0)

def note_ok(ip):
    with _LOCK:
        _FAILS.pop(ip, None)

def authed():
    return bool(session.get("u")) and session.get("pv") == pw_fingerprint()

@app.before_request
def guard():
    if request.path.startswith("/api/") and not authed():
        return jsonify({"error": "auth"}), 401

@app.after_request
def headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    if request.path.startswith("/api/") or request.path in ("/", "/login"):
        resp.headers["Cache-Control"] = "no-store"
    return resp

@app.get("/healthz")
def healthz():
    return "ok"

# 浏览器标签页图标 / iOS 添加到主屏幕的图标(和页面左上角的柱状图标一致)
FAVICON_ICO = base64.b64decode("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")
APPLE_ICON = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAALQAAAC0CAIAAACyr5FlAAAJxklEQVR42u3dW2wc9RXH8XPOfy676107vuBLcEKcBpQLKYFGuZQWqpRGtAjUm5CKClVfWwmpD1S8VFR9bV/6QhVVUIk+VO0DUFqQaBGiRC0hyI1Acm44JCSOMU5ix2vH3svMOX1Yh0Jrb7LLMk52f1+t8uB4d7Izn535zyrzH257dB8htFSCVYCAAwEHAg4EHAg4EHAg4EDAgYADAQdCwIGAAwEHAg4EHAg4EHAg4EDAgYADIeBAwIGAAwEHAg4EHAg4EHAg4EDAgRBwoGXzsApWMOZqf2sGHK1ogh2zmpXiuMqvBc4xkxnpCjEBjsTXuEihHM0Vy+y5/vaMLLP3ULMPZ+c1ip3n2kI/VgOOJs8Jz1xaGOxuf/iebXs3r7l1dbcnTET0cSFGxBTFdnRi+h/vjv/hreMjYxey6YA46QMNY8K4JGXk5woP7d74q+/cOdCRucpnleL4ly8feuIvB8PACXOSPlyw835stsRk/GjPbU89sieX8qNYjYip2ohUzdTIc3LXzavXdGefHT7he44JOJpNhuQvFR7avfGpR/ZEqpWfCDMzVXkIszCTUVl1+9renlz6+eETqdBPbOeB7zmSOF8tRtFgV/uvH/yS2eVNXsvTfSeR6o/v3nrv59fNLRSdMHA0y26DpbhQ+uGdm3qy6di0JhmLPi4fgH5yzzY1wp6jeVIz8b2vbVpjdoVBRrXtxGxEO9b1Dna1l+KYGTia4phSiuO+9szmgc7KMKLu1zGzjlS4ZaCzWIokER3AkchHkNlrxECBmTxJ7nwFOBLKrrHXAQ4EHAg4EHAg4EDAgYADAQcCDoSAAwEHAg4EHAg4EHAg4EDAgZqoVr8csvr/uTPgaE0TImxmZbVlCTB5wkJsZGrA0Ro55lKshWLknHS3BbLUHoKJ1GhqoRTF5jnOeC42A47ml5EvRv251AO7hnYO9Q71dHjMtsRl7hSpjV2cGz41+eLImdFzM9nAtdqBprVwCHO+GH1jy5qf7r0jE3pMV7iQJJfq3Njf+YMvbnr6n4d/s/9wylWuXQWO5txnlB+843OP7b1dmGM15ivMvMS2OCJ5eNfGG3LpX7w0nPZa6PxOWkfGbDH6+pa1j+29XUjMzHMiIrx4JerSDxFxTipHmXu33PTYV2+bK8XJXG0GHMmdm5Ri7culHt97uzAbqYjU9HTPiWP57vYNd67vm0/qakTgSORNChfK8QO3rUuHfqxWk4z/jlJNzez7O26xlvkGpCVwmJlzsnOoj4nqvtRUnAjzltVdvbmwHBsDR3McU8qxdWeC9T0dwswidb+OGWdCf31PRzFWboEjS6sMSJnJNWhzOgxI0bIHKZzKIgQcCDgQcCDgQMCBgAMBBwIOBBwIOBBwIAQcCDgQcCDgQMCBrq1W/qImXOcOHEuYYGIji6sQYHKXfw1KWgWHEEVGRSOPORcIL3edO9FcKY6MfKaASbG5mh6HEM0rd6bcV27qvaWvo689I7T0de4x2dRsYfTczL/PXBifLaTEGAeaJsYhxJeUtg92fWvbEBM5kep3tAs62nrbM3s2Dr5y5MzLR8d9ho8mxSFEl5S+PNRz39Z1nggZLV5hxLzEoIKZzHzHqkxEu9cPdKSDPx46FTJsNN2prDDNK39hsPO+resCzzGTc7wYEf9/l3/oHBtRypPNA93f3Lp2Xhnn302Fg4kipVUp9+1t6z0RM6vtfu5EzkkmcDvW9W3uzS7AR1PhYC4Y71h7AxOR1XljZiUysrs23EiMYUcT4TAzn+mWvk4nUvenXoh8kbVd2VWBxEaMrdcEOJgoNsoG0t+R8T7FvCeVkYjvpL8jUzYGjuYZkDI15rNuRIy9RpPhQMCBgAMBBwIOhIADAQcCDgQcCDgQcCDgQMCBgAMBB0LAgYADAQcCDgQcCDgQcCDgQMCBgAMh4EDAgYADAQcCDgQc112c4LM+u9e5tnAYkao1ZO1Y7bM+mVGkjZkrKq59NmU1K8cNmGO3ge/iWsFhRI5prqQXLhUjrX+iajMzo3KsEzPzPl/t6xiR73hqoTR2cU7NTLXud8Fs88Xye+dnQid2dcs3o8C5D/PzJ87njajud29GwjxTKI58MB0GniYy3XdyE8ZFRqPnZtTMtH5kZdUz03MXS+pqmTOOmaPYhk9NVtZynUtXVbORienJ2aLvapgMVZg1il87fra+fd5H+x4zeuv9ybNT+cC5ZKaCT3LCOBs+PRl6zjm2ut5cRdVbpz40I65lSjBV8h2/OHLaiTgnVu9nl4heePskWW2HfjX1fPf7A8fKqkxc33ZVMmb63b+OklFis6G5YOf9ySzJE5ouqsfU155xzCK1vcUo1lKso5MzLx0ZT0vNazhwMpFf8J3currbzGpdeqkcEfP+0fEnXx/Jhq6m474Rhb43diGfCvy7b15dVnW1Lj3SwMlzb7/3s+cO5DKhJnULieRwGJHPdPz8bG827MqmPWGlq5qQNDYzolKkM/OFZw6OkqpwPUsPnBw4OXnjqsyG3lVMpmZ8pf2PEamqqRHz++fzjz//hpnVMV2dmYW+98rhM2u6c9vX3hCrmRFfafdnRmqmRr6T4dPnvvfbvykZS3LnK8nhqOyLhemdD2ZWpf2BjrZYTa60os0oUlWz0cn8MwffXShHfr0z1DKRCL96bLwrE24a6Fw88TE2UzM2o08+1OzylOxM+0fHH3/+jdlCOXCuzqUzifCzh050taV2re8XZmZSMyNa7iHMlcefhkcffvrv0wvFwPeSvPFMojgq28Njemcif3ZqriPtZ0OfmNVouUc51tNTc68cPfvSkbNk6n26uYuFyBd+9fjZw+NT3W2pzkzoe0LMi/NgfuLBxDRfLL89dmHf/sNPvj6iZoFzn2aXLsK+5/586MSbpyY7M6mebCoT+Lx8Fy4VXj029sRfD/78hTdjs9D3VBOduZnbHt23Il+9FZSNaFUo/e0ZZlnydjxmOpGfv1hUI0qLUYNupuGYZ0sREfXn0kM97Uue+FQm1j15Pj8xu2BGudAzsoZ8ap1wfqFERIOd2c0DXZXxx//ca4aIYrXDH0yNTc+RWS4TWqMWf+3j+Gh1xEZlq3Zk8dkcL961qZE6mYmoFGup6ndTgZPACdf1xVd1H2RUjOJiFC97bs0ceq5ye4lYV2aq9xW7x5stfojJ8bI67PKfDV83laODLxw4r/pA8rM4NahsbN+T0HfV/5FqtoL3AFjhu0Pax/5ckaXbyt1Z0KzBO6Tr9UswdD0GHAg4EHAg4EDAgYADAQcCDgQcCDgQcCAEHAg4EHAg4EDAgYADAQcCDgQcCDgQAg4EHAg4EHAg4EDAgYADAQcCDgQcCNF/ABtx0ofR4YxNAAAAAElFTkSuQmCC")
FAVICON_SVG = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#0b6e99"/><rect x="12.8" y="31.6" width="7.8" height="19.6" rx="2.7" fill="#fff"/><rect x="26.4" y="21.9" width="7.8" height="29.3" rx="2.7" fill="#fff"/><rect x="40" y="12.8" width="7.8" height="38.4" rx="2.7" fill="#fff"/></svg>'

def _icon(data, mime):
    resp = Response(data, mimetype=mime)
    resp.headers["Cache-Control"] = "public, max-age=604800"
    return resp

@app.get("/favicon.ico")
def favicon():
    return _icon(FAVICON_ICO, "image/x-icon")

@app.get("/favicon.svg")
def favicon_svg():
    return _icon(FAVICON_SVG, "image/svg+xml")

@app.get("/apple-touch-icon.png")
@app.get("/apple-touch-icon-precomposed.png")
def apple_icon():
    return _icon(APPLE_ICON, "image/png")

@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return render_template_string(LOGIN, error="", title=site_title())
    ip = request.remote_addr or "?"
    if blocked(ip):
        return render_template_string(LOGIN, error="尝试次数过多,请 10 分钟后再试", title=site_title()), 429
    if check_credentials(request.form.get("user", ""), request.form.get("password", "")):
        note_ok(ip)
        session.clear()
        session["u"] = current_user()
        session["pv"] = pw_fingerprint()
        session.permanent = True
        return redirect("/")
    note_fail(ip)
    return render_template_string(LOGIN, error="账号或密码错误", title=site_title()), 401

@app.post("/logout")
def logout():
    session.clear()
    return redirect("/")

@app.get("/")
def index():
    if not authed():
        return render_template_string(LOGIN, error="", title=site_title())
    return render_template_string(PAGE, user=session["u"], title=site_title())

def _dir_bytes(path, prefix=""):
    total = 0
    try:
        for fn in os.listdir(path):
            if prefix and not fn.startswith(prefix):
                continue
            fp = os.path.join(path, fn)
            if os.path.isfile(fp):
                total += os.path.getsize(fp)
    except OSError:
        pass
    return total

@app.get("/api/storage")
def api_storage():
    con = db()
    oldest = con.execute("SELECT MIN(t) FROM req").fetchone()[0]
    trim = con.execute("SELECT v FROM meta WHERE k='last_trim'").fetchone()
    con.close()
    dbb, logs = storage_usage()
    trim_ts, trim_what = "", ""
    if trim and "|" in trim[0]:
        a, _, b = trim[0].partition("|")
        trim_ts, trim_what = fmt_epoch(int(a)), b.replace(";", "、")
    try:
        du = shutil.disk_usage(DATA_DIR)
        disk_total, disk_free = du.total, du.free
    except OSError:
        disk_total = disk_free = 0
    return jsonify({
        "db_bytes": dbb,
        "log_bytes": logs,
        "budget_bytes": STORAGE_MAX_MB * 1024 * 1024,
        "disk_total": disk_total, "disk_free": disk_free,
        "version": PANEL_VERSION, "project": PROJECT_URL,
        "detail_days": DETAIL_DAYS, "site_days": SITE_DAYS, "min_free_mb": MIN_FREE_MB,
        "oldest_detail": fmt_epoch(oldest) if oldest else "",
        "last_trim": trim_ts, "last_trim_what": trim_what,
    })

@app.post("/api/title")
def api_title():
    d = request.get_json(silent=True) or {}
    title = " ".join(str(d.get("title", "")).split())
    if len(title) > 40:
        return jsonify({"error": "标题最多 40 个字"}), 400
    s = load_settings()
    s["title"] = title
    save_settings(s)
    return jsonify({"ok": True, "title": title or DEFAULT_TITLE})

@app.post("/api/username")
def api_username():
    ip = request.remote_addr or "?"
    if blocked(ip):
        return jsonify({"error": "尝试次数过多,请 10 分钟后再试"}), 429
    d = request.get_json(silent=True) or {}
    new_user, pw = str(d.get("user", "")).strip(), str(d.get("password", ""))
    if not re.fullmatch(r"[A-Za-z0-9_.@\-]{2,32}", new_user):
        return jsonify({"error": "用户名需 2–32 位,只能用字母、数字和 _ . @ -"}), 400
    old_user = current_user()
    if not check_credentials(old_user, pw):
        note_fail(ip)
        return jsonify({"error": "当前密码不正确"}), 400
    if new_user == old_user:
        return jsonify({"error": "新用户名和当前用户名相同"}), 400
    save_password(new_user, pw)
    note_ok(ip)
    session["u"] = new_user
    session["pv"] = pw_fingerprint()
    return jsonify({"ok": True, "user": new_user})

@app.post("/api/password")
def api_password():
    ip = request.remote_addr or "?"
    if blocked(ip):
        return jsonify({"error": "尝试次数过多,请 10 分钟后再试"}), 429
    d = request.get_json(silent=True) or {}
    old, new = str(d.get("old", "")), str(d.get("new", ""))
    user = current_user()
    if not check_credentials(user, old):
        note_fail(ip)
        return jsonify({"error": "当前密码不正确"}), 400
    if not new:
        return jsonify({"error": "新密码不能为空"}), 400
    if len(new) > 128:
        return jsonify({"error": "新密码太长(最多 128 位)"}), 400
    if new == old:
        return jsonify({"error": "新密码不能和当前密码相同"}), 400
    save_password(user, new)
    note_ok(ip)
    session["pv"] = pw_fingerprint()
    return jsonify({"ok": True})

_spark_cache = (0.0, {})
_seen_sig = ((), 0.0)

def node_sparks():
    """每个节点最近 7 天(按显示时区分日)的连接请求数,5 分钟缓存一次"""
    global _spark_cache
    if time.time() - _spark_cache[0] < 300:
        return _spark_cache[1]
    off = int(DISPLAY_TZ.utcoffset(None).total_seconds())
    today = (int(time.time()) + off) // 86400
    start = (today - 6) * 86400 - off
    out = {}
    try:
        con = db()
        for port, d, n in con.execute(
                "SELECT port, (t + ?) / 86400 AS d, COUNT(*) FROM req WHERE t >= ? GROUP BY port, d", (off, start)):
            i = int(d) - (today - 6)
            if 0 <= i < 7:
                out.setdefault(port, [0] * 7)[i] = n
        con.close()
    except Exception as e:  # noqa
        print("spark error:", e, file=sys.stderr)
    _spark_cache = (time.time(), out)
    return out

@app.get("/api/overview")
def api_overview():
    """x-ui 里的全部端口 + 每个端口的当前在线数/历史 IP 数/访问网站数与常访网站"""
    live = live_map()
    con = db()
    hist = {r[0]: (r[1], r[2]) for r in con.execute(
        "SELECT port, COUNT(*), MAX(last_seen) FROM conn GROUP BY port")}
    site_rows = con.execute(
        "SELECT port, site, SUM(stay_secs), SUM(req_cnt), MAX(sample_host) "
        "FROM site_ip_stat GROUP BY port, site"
    ).fetchall()
    con.close()

    port_sites = {}
    for port, site, stay, reqs, sh in site_rows:
        name, _cat, is_aux = site_meta(site, sh)
        d = port_sites.setdefault(port, {"total": 0, "main": 0, "stay": 0, "list": []})
        d["total"] += 1
        d["stay"] += int(stay or 0)
        if not is_aux:
            d["main"] += 1
            d["list"].append((int(stay or 0), int(reqs or 0), name or site))

    rows, seen = [], set()
    sparks = node_sparks()

    def add(port, remark, protocol, enable, sniffing=None, up=0, down=0):
        l = live.get(port, {})
        h = hist.get(port, (0, None))
        ps = port_sites.get(port, {"total": 0, "main": 0, "stay": 0, "list": []})
        by_name = {}
        for stay_s, req_n, nm in ps["list"]:
            if nm.startswith("IP 直接连接"):
                continue
            a = by_name.setdefault(nm, [0, 0])
            a[0] += stay_s
            a[1] += req_n
        top3 = [n for n, _v in sorted(by_name.items(), key=lambda kv: (kv[1][0], kv[1][1]), reverse=True)[:3]]
        rows.append({
            "port": port, "remark": remark, "protocol": protocol,
            "enable": enable, "sniffing": sniffing,
            "online_ips": len(l), "conns": sum(l.values()),
            "hist_ips": h[0], "hist_sites": ps["total"], "main_sites": ps["main"],
            "total_stay_secs": ps["stay"], "top_sites": ", ".join(top3),
            "last_seen": fmt_ts(h[1]),
            "up": up, "down": down,
            "spark": sparks.get(port, []),
        })

    inbounds = xui_inbounds()
    for i in inbounds:
        seen.add(i["port"])
        add(i["port"], i["remark"], i["protocol"], i["enable"], i.get("sniffing"), i.get("up", 0), i.get("down", 0))
    # 记住每个节点的名字,节点从 x-ui 删除后仍能显示原名
    con = db()
    global _seen_sig
    sig = tuple((i["port"], i["remark"], i["protocol"]) for i in inbounds)
    if inbounds and (sig != _seen_sig[0] or time.time() - _seen_sig[1] > 3600):
        now = int(time.time())       # 只在节点列表有变化时写(或每小时刷新一次时间),平时不写数据库
        con.executemany("REPLACE INTO node_seen(port, remark, protocol, last_ts) VALUES(?,?,?,?)",
                        [(i["port"], i["remark"], i["protocol"], now) for i in inbounds])
        con.commit()
        _seen_sig = (sig, time.time())
    names = {r[0]: (r[1], r[2], r[3]) for r in con.execute("SELECT port, remark, protocol, last_ts FROM node_seen")}
    con.close()
    # 已从 x-ui 删除、但面板里还有历史数据的节点(只在能读到 x-ui 时判断,读不到就不乱标)
    if inbounds:
        for port in sorted(set(hist) | set(port_sites)):
            if port in seen:
                continue
            nm, proto, last_ts = names.get(port, ("", "", 0))
            add(port, nm, proto, None, None)
            rows[-1]["deleted"] = True
            rows[-1]["deleted_seen"] = fmt_epoch(last_ts) if last_ts else ""
    return jsonify(rows)

@app.post("/api/purge")
def api_purge():
    """彻底清除一个已从 x-ui 删除的节点的全部数据(x-ui 里还存在的节点不允许清除)"""
    d = request.get_json(silent=True) or {}
    port = str(d.get("port", "")).strip()
    if not port:
        return jsonify({"error": "缺少端口"}), 400
    inbounds = xui_inbounds()
    if not inbounds:
        return jsonify({"error": "读不到 x-ui 数据库,为安全起见暂不允许清除"}), 400
    if port in {i["port"] for i in inbounds}:
        return jsonify({"error": "这个端口在 x-ui 里还存在,不能清除"}), 400
    con = db()
    n = 0
    for tb in ("conn", "req", "sess", "site_ip_stat", "site_sub", "site_sess"):
        n += con.execute(f"DELETE FROM {tb} WHERE port = ?", (port,)).rowcount
    con.execute("DELETE FROM node_seen WHERE port = ?", (port,))
    con.commit()
    try:
        con.execute("PRAGMA incremental_vacuum").fetchall()
        con.commit()
    except Exception:
        pass
    con.close()
    global _ports_cache
    _ports_cache = (0.0, set())
    return jsonify({"ok": True, "rows": n})

def query_ips(port, q=""):
    con = db()
    rows = con.execute(
        """SELECT c.ip, g.country, g.region, g.city, g.isp, g.org, g.asn, g.mobile, g.hosting, g.proxy,
                  c.first_seen, c.last_seen, c.cnt, c.email
           FROM conn c LEFT JOIN geo g ON g.ip = c.ip
           WHERE c.port = ? ORDER BY c.last_seen DESC""",
        (port,),
    ).fetchall()
    s_rows = con.execute(
        "SELECT ip, site, stay_secs, req_cnt, sample_host FROM site_ip_stat WHERE port=?",
        (port,),
    ).fetchall()
    con.close()

    ip_sites = {}
    for ip, site, stay, reqs, sh in s_rows:
        name, _cat, is_aux = site_meta(site, sh)
        d = ip_sites.setdefault(ip, {"cnt": 0, "main_cnt": 0, "stay": 0, "list": []})
        d["cnt"] += 1
        d["stay"] += int(stay or 0)
        if not is_aux:
            d["main_cnt"] += 1
            d["list"].append((int(stay or 0), int(reqs or 0), name or site))

    out = []
    for ip, country, region, city, isp, org, asn, mob, host, prox, first, last, cnt, email in rows:
        known = country is not None
        sd = ip_sites.get(ip, {"cnt": 0, "main_cnt": 0, "stay": 0, "list": []})
        top3 = [x[2] for x in sorted(sd["list"], key=lambda x: (x[0], x[1]), reverse=True)[:3]]
        item = {
            "ip": ip,
            "loc": loc_str(country, region, city) if known else "查询中…",
            "carrier": carrier(isp, org, asn) if known else "",
            "isp_raw": isp or "",
            "net": net_kind(mob, host, prox) if known else "",
            "first_seen": fmt_ts(first),
            "last_seen": fmt_ts(last),
            "cnt": cnt,
            "email": email or "",
            "site_cnt": sd["cnt"],
            "main_site_cnt": sd["main_cnt"],
            "stay_secs": sd["stay"],
            "top_sites": ", ".join(top3),
        }
        if q and q.lower() not in " ".join(str(v) for v in item.values()).lower():
            continue
        out.append(item)
    return out

@app.get("/api/ips")
def api_ips():
    return jsonify(query_ips(request.args.get("port", ""), request.args.get("q", "").strip()))

@app.get("/api/live")
def api_live():
    ips = live_map().get(request.args.get("port", ""), {})
    con = db()
    res = [{"ip": ip, "conns": n, **geo_info(con, ip)} for ip, n in sorted(ips.items())]
    con.close()
    return jsonify(res)

def query_port_sites(port, ip_filter="", q="", hide_aux=False, cat_filter="", sort_by="stay"):
    """查询某个端口(或该端口下某个 IP)访问过的全部网站汇总及停留时长"""
    con = db()
    if ip_filter:
        rows = con.execute(
            """SELECT site, MIN(first_ts), MAX(last_ts), SUM(req_cnt), SUM(visit_cnt),
                      SUM(stay_secs), MAX(max_stay_secs), COUNT(DISTINCT ip), MAX(sample_host)
               FROM site_ip_stat WHERE port=? AND ip=? GROUP BY site""",
            (port, ip_filter),
        ).fetchall()
        intervals = con.execute(
            "SELECT start_ts, end_ts FROM site_sess WHERE port=? AND ip=? AND end_ts > start_ts",
            (port, ip_filter),
        ).fetchall()
    else:
        rows = con.execute(
            """SELECT site, MIN(first_ts), MAX(last_ts), SUM(req_cnt), SUM(visit_cnt),
                      SUM(stay_secs), MAX(max_stay_secs), COUNT(DISTINCT ip), MAX(sample_host)
               FROM site_ip_stat WHERE port=? GROUP BY site""",
            (port,),
        ).fetchall()
        intervals = con.execute(
            "SELECT start_ts, end_ts FROM site_sess WHERE port=? AND end_ts > start_ts",
            (port,),
        ).fetchall()

    sub_counts = dict(con.execute(
        "SELECT site, COUNT(*) FROM site_sub WHERE port=? GROUP BY site", (port,)
    ).fetchall())
    con.close()

    active_secs = merged_duration(intervals)
    total_sites = 0
    main_sites = 0
    aux_sites = 0
    total_visits = 0
    total_reqs = 0
    total_stay_secs = 0
    cat_map = {}
    out = []

    for site, f_ts, l_ts, req_cnt, visit_cnt, stay_secs, max_stay, ip_cnt, sample_host in rows:
        req_cnt = int(req_cnt or 0)
        visit_cnt = max(int(visit_cnt or 0), 1)
        stay_secs = int(stay_secs or 0)
        max_stay = int(max_stay or 0)
        name, category, is_aux = site_meta(site, sample_host or "")

        total_sites += 1
        if is_aux:
            aux_sites += 1
        else:
            main_sites += 1

        if hide_aux and is_aux:
            continue

        c_stat = cat_map.setdefault(category, {"cat": category, "sites": 0, "stay_secs": 0, "reqs": 0})
        c_stat["sites"] += 1
        c_stat["stay_secs"] += stay_secs
        c_stat["reqs"] += req_cnt

        if cat_filter and category != cat_filter:
            continue

        avg_stay = int(round(stay_secs / visit_cnt)) if visit_cnt else 0
        item = {
            "site": site,
            "name": name,
            "category": category,
            "is_aux": is_aux,
            "first_ts": f_ts or 0,
            "last_ts": l_ts or 0,
            "first_seen": fmt_epoch(f_ts),
            "last_seen": fmt_epoch(l_ts),
            "req_cnt": req_cnt,
            "visit_cnt": visit_cnt,
            "stay_secs": stay_secs,
            "avg_stay_secs": avg_stay,
            "max_stay_secs": max_stay,
            "ip_cnt": int(ip_cnt or 1),
            "sub_cnt": int(sub_counts.get(site, 1)),
            "sample_host": sample_host or site,
        }
        if q:
            hay = f"{site} {name} {category} {sample_host}".lower()
            if q.lower() not in hay:
                continue

        total_visits += visit_cnt
        total_reqs += req_cnt
        total_stay_secs += stay_secs
        out.append(item)

    if sort_by == "reqs":
        out.sort(key=lambda x: (x["req_cnt"], x["stay_secs"], x["last_ts"]), reverse=True)
    elif sort_by == "visits":
        out.sort(key=lambda x: (x["visit_cnt"], x["stay_secs"], x["last_ts"]), reverse=True)
    elif sort_by == "last":
        out.sort(key=lambda x: (x["last_ts"], x["stay_secs"]), reverse=True)
    else:
        out.sort(key=lambda x: (x["stay_secs"], x["visit_cnt"], x["req_cnt"], x["last_ts"]), reverse=True)

    categories = sorted(cat_map.values(), key=lambda x: (x["stay_secs"], x["reqs"]), reverse=True)
    return {
        "summary": {
            "total_sites": total_sites,
            "main_sites": main_sites,
            "aux_sites": aux_sites,
            "shown_sites": len(out),
            "total_visits": total_visits,
            "total_reqs": total_reqs,
            "total_stay_secs": total_stay_secs,
            "active_secs": active_secs,
            "idle_gap_secs": SITE_IDLE_GAP,
            "categories": categories,
        },
        "rows": out,
    }

@app.get("/api/sites")
def api_sites():
    port = request.args.get("port", "")
    ip_filter = request.args.get("ip", "").strip()
    q = request.args.get("q", "").strip()
    hide_aux = request.args.get("hide_aux", "0") == "1"
    cat_filter = request.args.get("cat", "").strip()
    sort_by = request.args.get("sort", "stay").strip()
    return jsonify(query_port_sites(port, ip_filter, q, hide_aux, cat_filter, sort_by))

@app.get("/api/site_detail")
def api_site_detail():
    """某个端口下某个网站的深度详情:每次访问停留会话、全部子域名与目标端口、访问过该网站的客户端 IP 汇总"""
    port = request.args.get("port", "")
    site = request.args.get("site", "")
    ip_filter = request.args.get("ip", "").strip()
    now = int(time.time())
    con = db()

    if ip_filter:
        st = con.execute(
            """SELECT MIN(first_ts), MAX(last_ts), SUM(req_cnt), SUM(visit_cnt),
                      SUM(stay_secs), MAX(max_stay_secs), COUNT(DISTINCT ip), MAX(sample_host)
               FROM site_ip_stat WHERE port=? AND site=? AND ip=?""",
            (port, site, ip_filter),
        ).fetchone()
        s_rows = con.execute(
            """SELECT id, ip, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound, email
               FROM site_sess WHERE port=? AND site=? AND ip=?
               ORDER BY start_ts DESC, id DESC LIMIT 300""",
            (port, site, ip_filter),
        ).fetchall()
    else:
        st = con.execute(
            """SELECT MIN(first_ts), MAX(last_ts), SUM(req_cnt), SUM(visit_cnt),
                      SUM(stay_secs), MAX(max_stay_secs), COUNT(DISTINCT ip), MAX(sample_host)
               FROM site_ip_stat WHERE port=? AND site=?""",
            (port, site),
        ).fetchone()
        s_rows = con.execute(
            """SELECT id, ip, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound, email
               FROM site_sess WHERE port=? AND site=?
               ORDER BY start_ts DESC, id DESC LIMIT 300""",
            (port, site),
        ).fetchall()

    sub_rows = con.execute(
        """SELECT host, dst_port, net, outbound, first_ts, last_ts, req_cnt
           FROM site_sub WHERE port=? AND site=?
           ORDER BY req_cnt DESC, last_ts DESC LIMIT 300""",
        (port, site),
    ).fetchall()

    ip_rows = con.execute(
        """SELECT ip, first_ts, last_ts, req_cnt, visit_cnt, stay_secs, max_stay_secs
           FROM site_ip_stat WHERE port=? AND site=?
           ORDER BY stay_secs DESC, req_cnt DESC""",
        (port, site),
    ).fetchall()

    geo_cache = {}
    def get_geo(ip_addr):
        if ip_addr not in geo_cache:
            geo_cache[ip_addr] = geo_info(con, ip_addr)
        return geo_cache[ip_addr]

    sessions = []
    intervals = []
    for sid, ip, s_ts, e_ts, stay, r_cnt, sp, hosts, out, email in s_rows:
        g = get_geo(ip)
        is_live = (now - int(e_ts or 0)) <= 15
        if e_ts and s_ts and e_ts > s_ts:
            intervals.append((s_ts, e_ts))
        sessions.append({
            "id": sid,
            "ip": ip,
            "loc": g["loc"],
            "carrier": g["carrier"],
            "start": fmt_epoch(s_ts),
            "end": fmt_epoch(e_ts),
            "live": is_live,
            "stay_secs": int(stay or 0),
            "req_cnt": int(r_cnt or 1),
            "src_port": sp or 0,
            "hosts": hosts or site,
            "outbound": "直连" if out == "direct" else (out or "-"),
            "email": email or "",
        })

    subdomains = []
    for h, dp, net, out, f_ts, l_ts, r_cnt in sub_rows:
        subdomains.append({
            "host": h,
            "dst_port": dp,
            "target": f"{h}:{dp}" if dp else h,
            "net": (net or "tcp").upper(),
            "outbound": "直连" if out == "direct" else (out or "-"),
            "first_seen": fmt_epoch(f_ts),
            "last_seen": fmt_epoch(l_ts),
            "req_cnt": int(r_cnt or 0),
        })

    ip_list = []
    for ip, f_ts, l_ts, r_cnt, v_cnt, stay, m_stay in ip_rows:
        g = get_geo(ip)
        ip_list.append({
            "ip": ip,
            "loc": g["loc"],
            "carrier": g["carrier"],
            "net": g["net"],
            "first_seen": fmt_epoch(f_ts),
            "last_seen": fmt_epoch(l_ts),
            "req_cnt": int(r_cnt or 0),
            "visit_cnt": int(v_cnt or 1),
            "stay_secs": int(stay or 0),
            "max_stay_secs": int(m_stay or 0),
        })

    con.close()
    f_ts, l_ts, req_cnt, visit_cnt, stay_secs, max_stay, ip_cnt, sample_host = st if st else (0, 0, 0, 0, 0, 0, 0, "")
    visit_cnt = int(visit_cnt or 0)
    stay_secs = int(stay_secs or 0)
    name, category, is_aux = site_meta(site, sample_host or "")
    return jsonify({
        "port": port,
        "site": site,
        "name": name,
        "category": category,
        "is_aux": is_aux,
        "ip_filter": ip_filter,
        "first_seen": fmt_epoch(f_ts),
        "last_seen": fmt_epoch(l_ts),
        "req_cnt": int(req_cnt or 0),
        "visit_cnt": visit_cnt,
        "stay_secs": stay_secs,
        "active_secs": merged_duration(intervals),
        "avg_stay_secs": int(round(stay_secs / visit_cnt)) if visit_cnt else 0,
        "max_stay_secs": int(max_stay or 0),
        "ip_cnt": int(ip_cnt or 0),
        "sub_cnt": len(subdomains),
        "site_days": SITE_DAYS,
        "detail_days": DETAIL_DAYS,
        "sessions": sessions,
        "subdomains": subdomains,
        "ips": ip_list,
    })

@app.get("/api/site_requests")
def api_site_requests():
    """某个端口下某个网站的逐条原始连接请求记录"""
    port = request.args.get("port", "")
    site = request.args.get("site", "")
    ip_filter = request.args.get("ip", "").strip()
    try:
        offset = max(int(request.args.get("offset", "0")), 0)
    except ValueError:
        offset = 0
    con = db()
    if ip_filter:
        total = con.execute(
            "SELECT COUNT(*) FROM req WHERE port=? AND site=? AND ip=?", (port, site, ip_filter)
        ).fetchone()[0]
        rows = con.execute(
            "SELECT t, ip, src_port, host, dst_port, net, outbound FROM req "
            "WHERE port=? AND site=? AND ip=? ORDER BY t DESC, id DESC LIMIT 200 OFFSET ?",
            (port, site, ip_filter, offset),
        ).fetchall()
    else:
        total = con.execute(
            "SELECT COUNT(*) FROM req WHERE port=? AND site=?", (port, site)
        ).fetchone()[0]
        rows = con.execute(
            "SELECT t, ip, src_port, host, dst_port, net, outbound FROM req "
            "WHERE port=? AND site=? ORDER BY t DESC, id DESC LIMIT 200 OFFSET ?",
            (port, site, offset),
        ).fetchall()
    con.close()
    return jsonify({
        "total": total,
        "rows": [{
            "time": fmt_epoch(t),
            "ip": ip,
            "src_port": sp or 0,
            "target": f"{h}:{dp}" if dp else (h or site),
            "net": (n or "tcp").upper(),
            "outbound": "直连" if o == "direct" else (o or "-"),
        } for t, ip, sp, h, dp, n, o in rows],
    })

@app.get("/api/site_timeline")
def api_site_timeline():
    """某个端口(或该端口下某个 IP)按时间倒序排列的每次网站浏览停留时间轴"""
    port = request.args.get("port", "")
    ip_filter = request.args.get("ip", "").strip()
    q = request.args.get("q", "").strip().lower()
    hide_aux = request.args.get("hide_aux", "0") == "1"
    try:
        offset = max(int(request.args.get("offset", "0")), 0)
    except ValueError:
        offset = 0
    now = int(time.time())
    con = db()
    if ip_filter:
        rows = con.execute(
            """SELECT id, ip, site, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound
               FROM site_sess WHERE port=? AND ip=?
               ORDER BY start_ts DESC, id DESC LIMIT 1000""",
            (port, ip_filter),
        ).fetchall()
    else:
        rows = con.execute(
            """SELECT id, ip, site, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound
               FROM site_sess WHERE port=?
               ORDER BY start_ts DESC, id DESC LIMIT 1000""",
            (port,),
        ).fetchall()

    geo_cache = {}
    def get_geo(ip_addr):
        if ip_addr not in geo_cache:
            geo_cache[ip_addr] = geo_info(con, ip_addr)
        return geo_cache[ip_addr]

    filtered = []
    for sid, ip, site, s_ts, e_ts, stay, r_cnt, sp, hosts, out in rows:
        name, category, is_aux = site_meta(site, (hosts or "").split(", ")[0])
        if hide_aux and is_aux:
            continue
        g = get_geo(ip)
        if q:
            hay = f"{site} {name} {category} {ip} {g['loc']} {g['carrier']} {hosts}".lower()
            if q not in hay:
                continue
        filtered.append({
            "id": sid,
            "ip": ip,
            "loc": g["loc"],
            "carrier": g["carrier"],
            "site": site,
            "name": name,
            "category": category,
            "is_aux": is_aux,
            "start": fmt_epoch(s_ts),
            "end": fmt_epoch(e_ts),
            "live": (now - int(e_ts or 0)) <= 15,
            "stay_secs": int(stay or 0),
            "req_cnt": int(r_cnt or 1),
            "src_port": sp or 0,
            "hosts": hosts or site,
            "outbound": "直连" if out == "direct" else (out or "-"),
        })
    con.close()
    page = filtered[offset:offset + 200]
    return jsonify({"total": len(filtered), "rows": page})

@app.get("/api/detail")
def api_detail():
    """某个端口下某个 IP 的详情:访问过的网站汇总、网站浏览轨迹、TCP 连接会话(含时长)"""
    port, ip = request.args.get("port", ""), request.args.get("ip", "")
    con = db()
    now = time.time()
    sess, total_secs = [], 0
    rows = con.execute(
        "SELECT src_port, start_ts, last_ts, open, approx FROM sess "
        "WHERE port=? AND ip=? ORDER BY start_ts DESC LIMIT 300", (port, ip)).fetchall()
    for sp, s, l, op, ap in rows:
        r = con.execute(
            "SELECT COUNT(*), MIN(t), MAX(t) FROM req WHERE port=? AND ip=? AND src_port=? AND t BETWEEN ? AND ?",
            (port, ip, sp, s - 30, l + 10)).fetchone()
        s_rows = con.execute(
            "SELECT DISTINCT site FROM req WHERE port=? AND ip=? AND src_port=? AND t BETWEEN ? AND ? AND site != '' LIMIT 5",
            (port, ip, sp, s - 30, l + 10)).fetchall()
        start = min(s, r[1]) if r[1] else s
        end = None if op else max(l, r[2] or 0)
        secs = int((now if op else end) - start)
        total_secs += max(secs, 0)
        sess.append({
            "src_port": sp, "start": fmt_epoch(start), "end": fmt_epoch(end) if end else "",
            "open": bool(op), "approx": bool(ap), "seconds": max(secs, 0), "reqs": r[0],
            "sites": ", ".join(x[0] for x in s_rows) if s_rows else "-",
        })
    c = con.execute("SELECT COUNT(*), MIN(t), MAX(t) FROM req WHERE port=? AND ip=?", (port, ip)).fetchone()
    total = con.execute("SELECT cnt FROM conn WHERE port=? AND ip=?", (port, ip)).fetchone()
    info = geo_info(con, ip)
    con.close()

    site_data = query_port_sites(port, ip_filter=ip, sort_by="stay")
    return jsonify({
        "ip": ip, "port": port, **info,
        "total_cnt": total[0] if total else 0, "detail_reqs": c[0],
        "detail_from": fmt_epoch(c[1]), "detail_to": fmt_epoch(c[2]),
        "detail_days": DETAIL_DAYS, "sessions": sess,
        "session_count": len(sess), "total_seconds": total_secs,
        "site_summary": site_data["summary"],
        "sites": site_data["rows"][:200],
    })

@app.get("/api/requests")
def api_requests():
    """某个 IP 的每次连接记录(时间、目标网站、来源端口、协议、出站线路)"""
    port, ip = request.args.get("port", ""), request.args.get("ip", "")
    try:
        offset = max(int(request.args.get("offset", "0")), 0)
    except ValueError:
        offset = 0
    con = db()
    total = con.execute("SELECT COUNT(*) FROM req WHERE port=? AND ip=?", (port, ip)).fetchone()[0]
    rows = con.execute(
        "SELECT t, src_port, net, outbound, host, dst_port, site FROM req WHERE port=? AND ip=? "
        "ORDER BY t DESC, id DESC LIMIT 200 OFFSET ?", (port, ip, offset)).fetchall()
    con.close()
    out_rows = []
    for t, sp, n, o, h, dp, site in rows:
        name, cat, _aux = site_meta(site or "", h or "", dp or 0) if site else ("", "", False)
        out_rows.append({
            "time": fmt_epoch(t),
            "src_port": sp,
            "target": f"{h}:{dp}" if dp else (h or "-"),
            "site": site or "-",
            "site_name": name or cat or "",
            "net": (n or "").upper(),
            "outbound": "直连" if o == "direct" else o,
        })
    return jsonify({"total": total, "rows": out_rows})

@app.get("/api/export")
def api_export():
    port = request.args.get("port", "")
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["IP", "归属地", "运营商", "网络类型", "原始运营商", "访问网站数(含主站)",
                "网站累计停留时长", "常访网站(前3)", "首次连接(北京时间)",
                "最近连接(北京时间)", "总连接次数", "用户"])
    for r in query_ips(port):
        w.writerow([
            r["ip"], r["loc"], r["carrier"], r["net"], r["isp_raw"],
            f"{r['site_cnt']} (主站 {r['main_site_cnt']})",
            fmt_dur_cn(r["stay_secs"]), r["top_sites"],
            r["first_seen"], r["last_seen"], r["cnt"], r["email"],
        ])
    return Response(
        "\ufeff" + buf.getvalue(), mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename=port-{port}-ips.csv"})

@app.get("/api/export_sites")
def api_export_sites():
    port = request.args.get("port", "")
    ip_filter = request.args.get("ip", "").strip()
    hide_aux = request.args.get("hide_aux", "0") == "1"
    data = query_port_sites(port, ip_filter=ip_filter, hide_aux=hide_aux, sort_by="stay")
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow([
        "网站主域名", "网站名称", "分类", "类型", "累计停留时长", "累计停留秒数",
        "平均每次停留", "最长单次停留", "访问停留次数", "连接请求数",
        "访问客户端IP数", "子域名/目标端口数", "代表目标地址",
        "首次访问(北京时间)", "最近访问(北京时间)"
    ])
    for r in data["rows"]:
        w.writerow([
            r["site"], r["name"] or "-", r["category"],
            "辅助/CDN/系统" if r["is_aux"] else "主站",
            fmt_dur_cn(r["stay_secs"]), r["stay_secs"],
            fmt_dur_cn(r["avg_stay_secs"]), fmt_dur_cn(r["max_stay_secs"]),
            r["visit_cnt"], r["req_cnt"], r["ip_cnt"], r["sub_cnt"],
            r["sample_host"], r["first_seen"], r["last_seen"],
        ])
    suffix = f"-{ip_filter}" if ip_filter else ""
    return Response(
        "\ufeff" + buf.getvalue(), mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename=port-{port}{suffix}-websites.csv"})

@app.get("/api/export_timeline")
def api_export_timeline():
    port = request.args.get("port", "")
    ip_filter = request.args.get("ip", "").strip()
    con = db()
    if ip_filter:
        rows = con.execute(
            """SELECT ip, site, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound
               FROM site_sess WHERE port=? AND ip=? ORDER BY start_ts DESC, id DESC LIMIT 5000""",
            (port, ip_filter),
        ).fetchall()
    else:
        rows = con.execute(
            """SELECT ip, site, start_ts, end_ts, stay_secs, req_cnt, src_port, hosts, outbound
               FROM site_sess WHERE port=? ORDER BY start_ts DESC, id DESC LIMIT 5000""",
            (port,),
        ).fetchall()
    geo_cache = {}
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow([
        "进入时间(北京时间)", "离开/最后活跃时间(北京时间)", "停留时长", "停留秒数",
        "网站主域名", "网站名称", "分类", "客户端IP", "归属地", "运营商",
        "期间请求次数", "客户端源端口", "访问子域名明细", "出站线路"
    ])
    for ip, site, s_ts, e_ts, stay, r_cnt, sp, hosts, out in rows:
        if ip not in geo_cache:
            geo_cache[ip] = geo_info(con, ip)
        g = geo_cache[ip]
        name, category, _aux = site_meta(site, (hosts or "").split(", ")[0])
        w.writerow([
            fmt_epoch(s_ts), fmt_epoch(e_ts), fmt_dur_cn(stay), int(stay or 0),
            site, name or "-", category, ip, g["loc"], g["carrier"],
            int(r_cnt or 1), sp or "", hosts or site,
            "直连" if out == "direct" else (out or "-"),
        ])
    con.close()
    suffix = f"-{ip_filter}" if ip_filter else ""
    return Response(
        "\ufeff" + buf.getvalue(), mimetype="text/csv",
        headers={"Content-Disposition": f"attachment; filename=port-{port}{suffix}-timeline.csv"})

STYLE = """
:root[data-theme=light]{color-scheme:light}
:root{--plug:#34c759;--bg:#edf1f5;--card:#ffffff;--fg:#17212b;--mut:#5f6c7b;--bd:#d8dfe7;--ac:#0b6e99;--hl:#e4f1f8;--ok:#13844a;--okbg:#e1f3e9;--err:#c62828;--warn:#a86200;--tag:#eef2f5;--ring:rgba(11,110,153,.25);--sh:0 1px 2px rgba(23,33,43,.06);
--mono:ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,monospace;color-scheme:light}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--plug:#30d158;--bg:#0d131a;--card:#141c25;--fg:#e2e8ee;--mut:#8d9aa8;--bd:#243140;--ac:#56b6e2;--hl:#152a3a;--ok:#3fcf82;--okbg:#11291d;--err:#ef6b6b;--warn:#e3a640;--tag:#1a2430;--ring:rgba(86,182,226,.32);--sh:none;color-scheme:dark}}
:root[data-theme=dark]{--plug:#30d158;--bg:#0d131a;--card:#141c25;--fg:#e2e8ee;--mut:#8d9aa8;--bd:#243140;--ac:#56b6e2;--hl:#152a3a;--ok:#3fcf82;--okbg:#11291d;--err:#ef6b6b;--warn:#e3a640;--tag:#1a2430;--ring:rgba(86,182,226,.32);--sh:none;color-scheme:dark}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
*{-webkit-tap-highlight-color:transparent}
body{margin:0;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);background:var(--bg);color:var(--fg);font:14px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC","HarmonyOS Sans SC","Microsoft YaHei","Noto Sans CJK SC",system-ui,sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased}
input,select,button,a.btn{font:inherit;height:34px;padding:0 12px;border:1px solid var(--bd);border-radius:8px;background:var(--card);color:var(--fg);text-decoration:none;display:inline-flex;align-items:center;gap:6px;transition:border-color .15s,background .15s,color .15s}
input{display:block}
button,a.btn,select{cursor:pointer;white-space:nowrap}
button:hover,a.btn:hover,select:hover{border-color:var(--ac);color:var(--ac)}
input:focus,select:focus{outline:none;border-color:var(--ac);box-shadow:0 0 0 3px var(--ring)}
:focus-visible{outline:2px solid var(--ac);outline-offset:2px}
button.pri{background:var(--ac);border-color:var(--ac);color:#fff;font-weight:600}
button.pri:hover{filter:brightness(1.08);color:#fff}
button.act{border-color:var(--ac);color:var(--ac);background:var(--hl);font-weight:600}
.mut{color:var(--mut)}
.bdg{display:inline-block;padding:1px 8px;border-radius:999px;font-size:12px;line-height:18px;background:var(--tag);color:var(--fg);margin-left:6px;font-weight:400;vertical-align:1px}
.bdg.main{background:var(--hl);color:var(--ac)}
.bdg.aux{color:var(--mut)}
/* 触屏设备:按钮加大到好点的尺寸;输入框 16px 防止 iOS 聚焦时自动放大页面 */
@media(pointer:coarse){
input,select,button,a.btn{height:40px}
input,select{font-size:16px}
}
"""

LOGIN = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#edf1f5" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0d131a" media="(prefers-color-scheme: dark)">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="{{ title }}">
<meta name="format-detection" content="telephone=no">
<script>(function(){try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}})()</script>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<title>登录 · {{ title }}</title>
<style>""" + STYLE + """
body{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:16px}
form{width:100%;max-width:360px;background:var(--card);border:1px solid var(--bd);border-radius:14px;padding:28px 26px 24px;box-shadow:var(--sh)}
.brand{display:flex;align-items:center;gap:10px;margin:0 0 6px}
h1{font-size:18px;margin:0;font-weight:650}
.lead{color:var(--mut);font-size:13px;margin:0 0 22px}
label{display:block;margin-bottom:14px;color:var(--mut);font-size:13px}
input{width:100%;margin-top:6px;height:40px;color:var(--fg)}
button{width:100%;height:40px;justify-content:center;margin-top:6px}
.err{color:var(--err);background:color-mix(in srgb,var(--err) 10%,transparent);border-radius:8px;padding:8px 10px;margin:0 0 14px;font-size:13px}
</style></head><body>
<form method="post" action="/login">
  <div class="brand"><svg class="logo" width="26" height="26" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="14" fill="var(--ac)"/><rect x="12.8" y="31.6" width="7.8" height="19.6" rx="2.7" fill="#fff"/><rect x="26.4" y="21.9" width="7.8" height="29.3" rx="2.7" fill="#fff"/><rect x="40" y="12.8" width="7.8" height="38.4" rx="2.7" fill="#fff"/></svg><h1>{{ title }}</h1></div>
  <p class="lead">查看每个节点的在线 IP 和访问过的网站</p>
  {% if error %}<p class="err">{{ error }}</p>{% endif %}
  <label>账号<input name="user" autocomplete="username" autofocus required></label>
  <label>密码<input name="password" type="password" autocomplete="current-password" required></label>
  <button class="pri" type="submit">登录</button>
</form></body></html>"""

PAGE = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#edf1f5" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0d131a" media="(prefers-color-scheme: dark)">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="{{ title }}">
<meta name="format-detection" content="telephone=no">
<script>(function(){try{var t=localStorage.getItem("theme");if(t==="light"||t==="dark")document.documentElement.setAttribute("data-theme",t)}catch(e){}})()</script>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<title>{{ title }}</title>
<style>""" + STYLE + """
main{max-width:1320px;margin:0 auto;padding:20px 20px 56px}
header{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin:0 0 20px}
.brand{display:flex;align-items:center;gap:10px}
h1{font-size:18px;margin:0;font-weight:650;letter-spacing:.01em}
h2{font-size:15px;margin:0 0 12px;font-weight:600}
.top{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.top form{margin:0}
.brand h1{margin-right:4px}
/* Telegram 设置 */
#tgdlg{width:min(620px,94vw)}
.tgh{display:flex;align-items:center;gap:10px}
.tgh h2{margin:0;font-size:17px}
.tgstate{margin:6px 0 4px;font-size:12.5px;color:var(--mut)}
.tgstate.ok{color:var(--ok)}
.tgs{border-top:1px solid var(--bd);padding:14px 0 4px;margin-top:10px}
.tgs h3{font-size:13px;font-weight:600;margin:0 0 10px;color:var(--fg)}
.fld{display:block;font-size:13px;color:var(--mut);margin-bottom:12px}
.fld input{width:100%;margin-top:6px}
.fld .row{display:flex;gap:8px;margin-top:6px}
.fld .row input{margin-top:0;flex:1;min-width:0}
.hint{display:block;font-size:12px;color:var(--mut);margin-top:5px}
.opts{display:flex;flex-direction:column;gap:2px}
.opt{display:flex;gap:10px;align-items:flex-start;padding:8px 10px;border-radius:10px;cursor:pointer}
.opt:hover{background:var(--tag)}
.opt>input[type=checkbox]{width:18px;height:18px;margin:2px 0 0;flex:none;accent-color:var(--ac);padding:0}
.opt b{display:block;font-size:13.5px;font-weight:600}
.opt i{display:block;font-style:normal;font-size:12px;color:var(--mut);margin-top:2px;line-height:2}
.opt input.num{display:inline-block;width:62px;height:26px;padding:0 6px;margin:0 2px;font-size:13px;text-align:center}
.opt input.tm{display:inline-block;width:118px;height:26px;padding:0 6px;margin:0 2px;font-size:13px}
.tgnodes{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
.tgnode{display:inline-flex;align-items:center;gap:6px;height:30px;padding:0 10px 0 8px;border:1px solid var(--bd);border-radius:999px;font-size:12.5px;cursor:pointer;user-select:none}
.tgnode input{width:15px;height:15px;margin:0;padding:0;accent-color:var(--ac)}
.tgnode.on{border-color:var(--ac);background:var(--hl);color:var(--ac)}
.tgnode small{color:var(--mut);font-size:11px}
.cmds{display:grid;grid-template-columns:1fr 1fr;gap:6px 14px;margin:8px 0 2px;font-size:12px;color:var(--mut)}
.cmds code{font:12px var(--mono);background:var(--tag);color:var(--fg);padding:1px 6px;border-radius:5px;margin-right:6px}
.tgfoot{margin:6px 0 0}
.sw{margin-left:auto;display:inline-flex;align-items:center;gap:8px;cursor:pointer;font-size:13px;color:var(--mut);user-select:none}
.sw input{position:absolute;opacity:0;width:1px;height:1px}
.sw .knob{width:38px;height:22px;border-radius:999px;background:var(--bd);position:relative;transition:background .15s;flex:none}
.sw .knob::after{content:"";position:absolute;top:3px;left:3px;width:16px;height:16px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25);transition:transform .15s}
.sw input:checked+.knob{background:var(--ok)}
.sw input:checked+.knob::after{transform:translateX(16px)}
.sw input:checked~.swt{color:var(--ok);font-weight:600}
.sw input:focus-visible+.knob{outline:2px solid var(--ac);outline-offset:2px}
@media(pointer:coarse){.opt input.num,.opt input.tm{font-size:16px;height:32px}}
@media(max-width:640px){.cmds{grid-template-columns:1fr}.tgfoot .grow{display:none}#tgdlg{width:100%}}
.foot{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:center;margin-top:22px;padding:14px 16px;border-radius:12px;border:1px dashed var(--bd);font-size:12.5px;color:var(--mut)}
.foot b{color:var(--fg);font-weight:600}
.foot .fh{font-size:13px}
.foot .fd{color:var(--mut)}
.foot .meter{box-shadow:inset 0 0 0 1px var(--bd);flex:0 0 140px;height:6px;border-radius:3px;background:var(--tag);overflow:hidden}
.foot .meter i{display:block;height:100%;background:var(--ac);border-radius:3px}
.foot .meter.hot i{background:var(--warn)}
.foot .note{flex-basis:100%;font-size:12px}
.foot .ver{font-size:12px;color:var(--mut);text-decoration:none;margin-left:auto}
.foot .ver:hover{color:var(--ac)}
.sync{display:inline-flex;align-items:center;gap:7px;height:24px;padding:0 10px;border-radius:999px;background:var(--card);border:1px solid var(--bd);font-size:12px;color:var(--mut);white-space:nowrap}
.sync i{width:6px;height:6px;border-radius:50%;background:var(--ok);flex:none}
.sync.busy i{animation:blink 1s ease-in-out infinite}
.sync.err{color:var(--err);border-color:color-mix(in srgb,var(--err) 40%,var(--bd))}
.sync.err i{background:var(--err)}
.sync b{font-weight:600;color:var(--fg)}
@keyframes blink{50%{opacity:.25}}
@media(prefers-reduced-motion:reduce){.sync.busy i{animation:none}}
.top{position:relative;display:flex;align-items:center;gap:8px}
.iconbtn{width:34px;height:34px;padding:0;justify-content:center;border-radius:50%;color:var(--mut);flex:none}
.iconbtn:hover{color:var(--fg);border-color:var(--bd);background:var(--tag)}
@media(pointer:coarse){.iconbtn{width:40px;height:40px}}
/* 骨架屏 */
.sk{display:block;height:12px;border-radius:6px;margin:8px 0;background:linear-gradient(90deg,var(--tag) 25%,color-mix(in srgb,var(--tag) 35%,var(--card)) 50%,var(--tag) 75%);background-size:200% 100%;animation:shim 1.3s linear infinite}
@keyframes shim{from{background-position:200% 0}to{background-position:-200% 0}}
@media(prefers-reduced-motion:reduce){.sk{animation:none}}
.node.skel{cursor:default;box-shadow:none}
.node.skel:hover{border-color:var(--bd)}
.sk.w30{width:30%}.sk.w45{width:45%}.sk.w60{width:60%}.sk.w80{width:80%}.sk.h20{height:20px}
tr.skrow td{padding:6px 12px}
tr.skrow:hover{background:none}
/* 节点趋势小图 */
.spark{margin-left:auto;flex:none;display:block;overflow:visible}
.spark .ln{fill:none;stroke:var(--ac);stroke-width:1.6;stroke-linejoin:round;stroke-linecap:round}
.spark .ar{fill:var(--ac);opacity:.12}
.spark .bs{stroke:var(--bd);stroke-width:1}
.spark .pt{fill:var(--ac);stroke:var(--card);stroke-width:1.5}
.spark rect{fill:transparent}
.spark rect:hover{fill:color-mix(in srgb,var(--ac) 10%,transparent)}
.acts{display:flex;gap:8px;align-items:center}
.acts form{margin:0}
.who{display:inline-flex;align-items:center;gap:9px;margin-right:6px;padding:0 14px 0 0;height:auto;border:0;border-right:1px solid var(--bd);border-radius:0;background:none;color:var(--fg);cursor:default;text-align:left}
.who:hover{color:var(--fg)}
.who .chev{display:none;color:var(--mut)}
.ava{width:30px;height:30px;border-radius:50%;display:grid;place-items:center;background:var(--ac);color:#fff;font-weight:700;font-size:13px;flex:none}
.who .wt{display:flex;flex-direction:column;line-height:1.2}
.who .wt span{font-size:11px;color:var(--mut)}
.who .wt b{font-size:13.5px;font-weight:600}
.counts{display:inline-flex;gap:6px;align-items:center}
.cnt{display:inline-flex;align-items:baseline;gap:5px;height:24px;padding:0 10px;border-radius:999px;background:var(--card);border:1px solid var(--bd);font-size:12px;color:var(--mut);line-height:22px;white-space:nowrap}
.cnt b{font-size:13px;font-weight:650;color:var(--fg)}
.cnt{align-items:center}
.cnt i{width:7px;height:7px;border-radius:50%;flex:none;background:var(--mut)}
.cnt.on{color:var(--ok);background:var(--okbg);border-color:transparent}
.cnt.on b{color:var(--ok)}
.cnt.on i{background:var(--ok)}
.cnt.off i{background:color-mix(in srgb,var(--mut) 55%,transparent)}
.cnt.none i{background:transparent;border:1.5px solid color-mix(in srgb,var(--mut) 60%,transparent);width:8px;height:8px}
.cnt.all{background:transparent;border-color:transparent;padding-left:2px}
.csep{width:1px;height:14px;background:var(--bd);margin:0 2px}
.sect-h h2{font-size:16px}
.sect-h{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;margin:0 0 12px}
.sect-h h2{margin:0}
/* 节点卡片 */
.grow{flex:1}
.seg{display:inline-flex;padding:3px;background:var(--tag);border-radius:9px;gap:2px}
.seg button{border:0;background:transparent;height:26px;padding:0 12px;border-radius:7px;color:var(--mut);font-size:13px}
.seg button:hover{color:var(--fg)}
.seg button.act{background:var(--card);color:var(--fg);font-weight:600;box-shadow:0 1px 2px rgba(0,0,0,.12)}
#ov{margin-bottom:28px}
.nodes{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px}
.node{position:relative;background:var(--card);border:1px solid var(--bd);border-radius:14px;padding:15px 17px 14px;cursor:pointer;box-shadow:var(--sh);overflow:hidden;transition:border-color .15s,box-shadow .15s,transform .15s}
.node:hover{border-color:color-mix(in srgb,var(--ac) 55%,var(--bd))}
.node.live{border-color:color-mix(in srgb,var(--ok) 45%,var(--bd))}
.node.live::after{content:"";position:absolute;inset:0 0 auto 0;height:3px;background:var(--ok)}
.node.sel{border-color:var(--ac);box-shadow:0 0 0 3px var(--ring)}
.node.off{opacity:.55}
.nh{display:flex;align-items:center;gap:8px;min-width:0}
.nm{font-size:16px;font-weight:650;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0}
.pn{display:inline-flex;align-items:center;gap:4px;height:20px;padding:0 7px;border-radius:6px;background:var(--tag);color:var(--mut);font-size:12px;font-weight:500;flex:none;letter-spacing:.02em}
.pn svg,.pp svg{color:var(--plug)}
.proto{margin-left:auto;flex:none;font-size:11.5px;font-weight:600;line-height:20px;padding:0 9px;border-radius:999px;letter-spacing:.02em;color:var(--pc);background:color-mix(in srgb,var(--pc) 12%,transparent)}
.proto,.pproto{--pc:#64748b}.proto.vmess,.pproto.vmess{--pc:#7c3aed}.proto.vless,.pproto.vless{--pc:#0e7490}.proto.trojan,.pproto.trojan{--pc:#c2410c}.proto.shadowsocks,.pproto.shadowsocks{--pc:#2563eb}.proto.hysteria2,.pproto.hysteria2,.proto.hysteria,.pproto.hysteria{--pc:#be185d}.proto.wireguard,.pproto.wireguard{--pc:#4d7c0f}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]) .proto,:root:not([data-theme=light]) .pproto{--pc:#94a3b8}:root:not([data-theme=light]) .proto.vmess,:root:not([data-theme=light]) .pproto.vmess{--pc:#a78bfa}:root:not([data-theme=light]) .proto.vless,:root:not([data-theme=light]) .pproto.vless{--pc:#22d3ee}:root:not([data-theme=light]) .proto.trojan,:root:not([data-theme=light]) .pproto.trojan{--pc:#fb923c}:root:not([data-theme=light]) .proto.shadowsocks,:root:not([data-theme=light]) .pproto.shadowsocks{--pc:#60a5fa}:root:not([data-theme=light]) .proto.hysteria2,:root:not([data-theme=light]) .pproto.hysteria2,:root:not([data-theme=light]) .proto.hysteria,:root:not([data-theme=light]) .pproto.hysteria{--pc:#f472b6}:root:not([data-theme=light]) .proto.wireguard,:root:not([data-theme=light]) .pproto.wireguard{--pc:#a3e635}}
:root[data-theme=dark] .proto,:root[data-theme=dark] .pproto{--pc:#94a3b8}:root[data-theme=dark] .proto.vmess,:root[data-theme=dark] .pproto.vmess{--pc:#a78bfa}:root[data-theme=dark] .proto.vless,:root[data-theme=dark] .pproto.vless{--pc:#22d3ee}:root[data-theme=dark] .proto.trojan,:root[data-theme=dark] .pproto.trojan{--pc:#fb923c}:root[data-theme=dark] .proto.shadowsocks,:root[data-theme=dark] .pproto.shadowsocks{--pc:#60a5fa}:root[data-theme=dark] .proto.hysteria2,:root[data-theme=dark] .pproto.hysteria2,:root[data-theme=dark] .proto.hysteria,:root[data-theme=dark] .pproto.hysteria{--pc:#f472b6}:root[data-theme=dark] .proto.wireguard,:root[data-theme=dark] .pproto.wireguard{--pc:#a3e635}
.flag{font-size:11px;line-height:17px;padding:0 7px;border-radius:999px;background:var(--tag);color:var(--mut);flex:none}
.flag.w{color:var(--warn);background:color-mix(in srgb,var(--warn) 13%,transparent)}
.st{display:flex;align-items:center;gap:12px;margin:10px 0 14px;font-size:13px;color:var(--mut);white-space:nowrap;min-height:22px}
.sbadge{display:inline-flex;align-items:center;gap:6px;height:22px;padding:0 9px 0 8px;border-radius:999px;font-size:12px;font-weight:600;background:var(--tag);color:var(--mut);flex:none}
.node.live .sbadge{background:var(--okbg);color:var(--ok)}
.sstat{display:inline-flex;align-items:baseline;gap:3px}
.sstat b{font-size:14px;font-weight:650;color:var(--fg)}
.st .snote{overflow:hidden;text-overflow:ellipsis}
.dot{width:7px;height:7px;border-radius:50%;background:color-mix(in srgb,var(--mut) 45%,transparent);flex:none}
.live .dot{background:var(--ok);animation:ping 2.4s ease-out infinite}
@keyframes ping{0%{box-shadow:0 0 0 0 color-mix(in srgb,var(--ok) 55%,transparent)}70%,100%{box-shadow:0 0 0 7px transparent}}
@media(prefers-reduced-motion:reduce){.live .dot{animation:none}}
.kv{display:grid;grid-template-columns:repeat(var(--n,3),auto);justify-content:space-between;column-gap:12px}
.kv div{display:flex;flex-direction:column}
.kv b{font-size:18px;font-weight:650;line-height:1.15;letter-spacing:-.01em;white-space:nowrap}
.kv span{font-size:12px;color:var(--mut);margin-top:2px}
.tops{display:flex;gap:6px;flex-wrap:nowrap;overflow:hidden;margin-top:13px;padding-top:12px;border-top:1px dashed var(--bd);min-height:33px}
.tops span{font-size:12px;line-height:21px;height:21px;padding:0 9px;border-radius:6px;background:var(--hl);color:var(--ac);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0;flex:0 1 auto;max-width:48%}
.tops .none{background:none;color:var(--mut);padding:0;max-width:none}
/* 折叠的空闲节点 & 精简视图 */
.idle-grp{margin-top:12px}
.idle-grp summary{display:inline-flex;align-items:center;gap:8px;cursor:pointer;color:var(--mut);font-size:13px;list-style:none;padding:6px 12px 6px 10px;border-radius:8px;user-select:none}
.idle-grp summary::-webkit-details-marker{display:none}
.idle-grp summary:hover{color:var(--fg);background:var(--tag)}
.idle-grp summary::before{content:"";width:6px;height:6px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;transform:rotate(-45deg);transition:transform .15s}
.idle-grp[open] summary::before{transform:rotate(45deg)}
.pills{display:flex;flex-wrap:wrap;gap:8px;margin-top:8px}
.pgrp{display:grid;grid-template-columns:64px 1fr;gap:10px;align-items:start;padding:10px 0;border-top:1px solid var(--bd)}
.pgrp:first-child{border-top:0;padding-top:0}
.pgrp>.ph{display:flex;align-items:center;gap:6px;height:36px;font-size:13px;font-weight:600;color:var(--mut)}
.pgrp>.ph b{font-weight:600;color:var(--fg)}
.pgrp .pills{margin-top:0}
.pill{display:inline-flex;align-items:center;gap:8px;height:36px;padding:0 12px 0 11px;border:1px solid var(--bd);border-radius:10px;background:var(--card);cursor:pointer;font-size:13px;white-space:nowrap;box-shadow:var(--sh);transition:border-color .15s,box-shadow .15s}
.pill:hover{border-color:color-mix(in srgb,var(--ac) 55%,var(--bd))}
.pill b{font-weight:600}
.pill .pp{display:inline-flex;align-items:center;gap:3px;font-size:11.5px;font-weight:500;color:var(--mut);background:var(--tag);border-radius:5px;padding:0 6px;line-height:20px;height:20px}
.pill .pm{font-size:12px;color:var(--mut);display:inline-flex;align-items:baseline;gap:3px}
.pill .pm strong{font-size:13px;font-weight:650;color:var(--fg)}
.pill .pm .gap{width:6px}
.pill.live{background:color-mix(in srgb,var(--okbg) 70%,var(--card));border-color:color-mix(in srgb,var(--ok) 40%,var(--bd))}
.pill.live .pm strong{color:var(--ok)}
.pill.unused{background:transparent;border-style:dashed;box-shadow:none;color:var(--mut)}
.pill.unused b{font-weight:500}
.pill.unused .dot{background:transparent;border:1.5px solid color-mix(in srgb,var(--mut) 60%,transparent);width:8px;height:8px}
.pill.sel{border-color:var(--ac);border-style:solid;box-shadow:0 0 0 3px var(--ring)}
.pill.off{opacity:.55}
.del-grp{margin-top:8px}
.delwrap{display:inline-flex;align-items:stretch;gap:0}
.delwrap .pill{height:auto;min-height:36px}
.pill.deleted{border-style:dashed;background:transparent;box-shadow:none;border-radius:10px 0 0 10px;border-right:0}
.pill.deleted b{color:var(--mut);font-weight:500}
.purge{height:auto;border-radius:0 10px 10px 0;border:1px dashed color-mix(in srgb,var(--err) 45%,var(--bd));color:var(--err);background:transparent;font-size:12px;padding:0 10px}
.purge:hover{background:color-mix(in srgb,var(--err) 10%,transparent);color:var(--err);border-color:var(--err)}
.pill .pproto{width:3px;height:16px;border-radius:2px;background:var(--pc);flex:none;margin-left:-3px}
/* 详情区 */
.dhead{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin:0 0 12px}
.dhead h2{font-size:20px;font-weight:650;margin:0}
.card{background:var(--card);border:1px solid var(--bd);border-radius:12px;padding:18px 18px 16px;margin-bottom:14px;box-shadow:var(--sh)}
.bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px}
input[type=search],input.q{min-width:240px}
.tw{overflow-x:auto;border:1px solid var(--bd);border-radius:10px}
.scroll{max-height:56vh;overflow:auto;border:1px solid var(--bd);border-radius:10px}
table{width:100%;border-collapse:collapse;white-space:nowrap}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--bd)}
tbody tr:last-child td{border-bottom:0}
th{color:var(--mut);font-weight:500;font-size:12.5px;background:var(--tag);position:sticky;top:0;z-index:1}
tbody tr:hover{background:color-mix(in srgb,var(--hl) 60%,transparent)}
tr.click{cursor:pointer}
tr.sel{background:var(--hl)}
.on{color:var(--ok);font-weight:600}
.empty{padding:28px 16px;text-align:center;color:var(--mut);white-space:normal}
.sub{font-weight:400;color:var(--mut);font-size:13px}
p.sub{line-height:1.6}
button.lnk{border:0;background:none;height:auto;padding:0;color:var(--ac);cursor:pointer;text-align:left;font-weight:500;display:inline}
button.lnk:hover{text-decoration:underline;text-underline-offset:3px}
dialog{border:1px solid var(--bd);border-radius:14px;background:var(--card);color:var(--fg);padding:20px 22px;width:min(1100px,96vw);max-height:92vh;box-shadow:0 24px 60px rgba(0,0,0,.28)}
dialog::backdrop{background:rgba(13,19,26,.5);backdrop-filter:blur(2px)}
dialog .dh{padding-bottom:12px;margin-bottom:4px;border-bottom:1px solid var(--bd)}
dialog h2{font-size:17px}
.chips{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0 12px}
.chip{background:var(--tag);border:1px solid transparent;border-radius:8px;padding:4px 11px;font-size:13px}
#siteChips .chip,#chips .chip,#sdchips .chip{background:var(--hl);color:var(--fg)}
.chip.click{cursor:pointer;background:transparent;border-color:var(--bd);border-radius:999px}
.chip.click:hover{border-color:var(--ac);color:var(--ac)}
.chip.act{border-color:var(--ac);color:var(--ac);background:var(--hl);font-weight:600}
.tabs{display:inline-flex;gap:2px;flex-wrap:wrap;margin:6px 0 12px;padding:3px;background:var(--tag);border-radius:10px}
.tabs button{border:0;background:transparent;height:30px;border-radius:8px;color:var(--mut)}
.tabs button:hover{color:var(--fg)}
.tabs button.act{background:var(--card);color:var(--ac);box-shadow:0 1px 2px rgba(0,0,0,.12)}
.dh{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap}
.msg{min-height:20px;margin:8px 0;font-size:13px}
.msg.e{color:var(--err)}.msg.o{color:var(--ok)}
.pw{min-width:0}
#titledlg,#userdlg,#pwdlg{width:min(420px,92vw)}
.pw h2{margin-bottom:16px}
.pw label{display:block;margin-bottom:12px;color:var(--mut);font-size:13px}
.pw input{width:100%;margin-top:6px;color:var(--fg)}
.trunc{max-width:260px;overflow:hidden;text-overflow:ellipsis}
/* ===== iPad 竖屏及以下(≤ 1024px):宽表格首列固定,左右滑动时仍能看到是哪个 IP / 网站 ===== */
@media(max-width:1024px){
main{padding:18px 18px 48px}
.tw td:first-child,.tw th:first-child,.scroll td:first-child,.scroll th:first-child{position:sticky;left:0;z-index:1;background:var(--card);box-shadow:1px 0 0 var(--bd)}
.tw th:first-child,.scroll th:first-child{z-index:2;background:var(--tag)}
.tw td:first-child,.scroll td:first-child{max-width:340px;overflow:hidden;text-overflow:ellipsis}
tbody tr:hover td:first-child{background:color-mix(in srgb,var(--hl) 60%,var(--card))}
dialog{width:min(1100px,94vw)}
}
/* ===== iPad 竖屏 / 小平板(≤ 900px):账户操作收进头像菜单 ===== */
@media(max-width:900px){
.who{cursor:pointer;border-right:0;padding:4px 10px 4px 4px;margin:0;border-radius:999px;border:1px solid var(--bd);background:var(--card)}
.who .chev{display:block}
.acts{display:none;position:absolute;right:0;top:calc(100% + 8px);z-index:20;flex-direction:column;align-items:stretch;gap:2px;min-width:176px;padding:6px;background:var(--card);border:1px solid var(--bd);border-radius:12px;box-shadow:0 12px 32px rgba(0,0,0,.18)}
.top.open .acts{display:flex}
.top.open .who .chev{transform:rotate(180deg)}
.acts button{width:100%;justify-content:flex-start;border:0;background:none;border-radius:8px}
.acts button:hover{background:var(--tag);color:var(--fg)}
.acts form{border-top:1px solid var(--bd);margin-top:4px;padding-top:4px}
.acts .logout{color:var(--err)}
.nodes{grid-template-columns:repeat(2,minmax(0,1fr))}
}
/* ===== 手机(≤ 640px) ===== */
@media(max-width:640px){
main{padding:12px 12px 40px}
header{margin-bottom:14px;flex-wrap:nowrap;align-items:flex-start}
.brand{flex-wrap:wrap;row-gap:6px;min-width:0}
.brand h1{font-size:17px}
.who .wt{display:none}
.top{flex-wrap:nowrap;flex:none;gap:6px}
.who{padding:3px 8px 3px 3px}
.sect-h{gap:8px}
.counts{order:3;width:100%;overflow-x:auto;scrollbar-width:none}
.counts::-webkit-scrollbar{display:none}
/* 节点卡片改为横向滑动 */
.nodes{display:flex;grid-template-columns:none;overflow-x:auto;scroll-snap-type:x mandatory;gap:10px;margin:0 -12px;padding:4px 12px 8px;scrollbar-width:none;overscroll-behavior-x:contain}
.nodes::-webkit-scrollbar{display:none}
.node{flex:0 0 84%;scroll-snap-align:center;padding:13px 14px 12px}
.node:only-child{flex-basis:100%}
.kv b{font-size:17px}
#ov{margin-bottom:22px}
.pill{height:34px;padding:0 10px}
.pgrp{grid-template-columns:1fr;gap:6px}
.pgrp>.ph{height:auto}
/* 详情区 */
.dhead{margin-bottom:10px}
.dhead h2{font-size:18px;width:100%}
.dhead .bar,.chips,.tabs{flex-wrap:nowrap;overflow-x:auto;scrollbar-width:none;max-width:100%}
.dhead .bar::-webkit-scrollbar,.chips::-webkit-scrollbar,.tabs::-webkit-scrollbar{display:none}
.dhead .bar{margin:0 -12px!important;padding:0 12px 2px}
.chip,.tabs button{flex:none}
.card{padding:14px 12px;border-radius:12px}
.card h2 .sub{display:block;margin-top:2px}
.bar input.q,.bar input[type=search]{min-width:0;width:100%;flex:1 1 100%}
.bar>select{flex:1 1 40%;min-width:0}
#toggleAux{flex:1 1 100%;justify-content:center}
th,td{padding:8px 10px}
p.sub{font-size:12px}
.tw td:first-child,.scroll td:first-child{max-width:52vw;min-width:120px;white-space:normal;overflow:visible}
.tw td:first-child .bdg,.scroll td:first-child .bdg{display:block;width:max-content;max-width:100%;margin:3px 0 0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tw td:first-child button.lnk,.scroll td:first-child button.lnk{word-break:break-all}
/* 弹窗改为底部抽屉 */
dialog{width:100%;max-width:100%;max-height:92dvh;margin:auto 0 0;border-radius:18px 18px 0 0;padding:14px 14px calc(16px + env(safe-area-inset-bottom));border-left:0;border-right:0;border-bottom:0}
dialog::before{content:"";display:block;width:36px;height:4px;border-radius:2px;background:var(--bd);margin:0 auto 10px}
dialog .dh{flex-wrap:nowrap}
dialog .dh>div{min-width:0}
dialog h2{font-size:16px}
.scroll{max-height:62dvh}
#titledlg,#userdlg,#pwdlg{width:100%}
}
@media(max-width:360px){.node{flex-basis:90%}}
</style></head><body><main>
<header>
<div class="brand"><svg class="logo" width="26" height="26" viewBox="0 0 64 64" aria-hidden="true"><rect width="64" height="64" rx="14" fill="var(--ac)"/><rect x="12.8" y="31.6" width="7.8" height="19.6" rx="2.7" fill="#fff"/><rect x="26.4" y="21.9" width="7.8" height="29.3" rx="2.7" fill="#fff"/><rect x="40" y="12.8" width="7.8" height="38.4" rx="2.7" fill="#fff"/></svg><h1 id="siteTitle">{{ title }}</h1><span class="sync busy" id="upd" title="每 10 秒自动刷新一次"><i></i><span>正在加载…</span></span></div>
<div class="top" id="top">
<button type="button" class="iconbtn" id="themeBtn" aria-label="切换外观"></button>
<button type="button" class="who" id="acctBtn" aria-haspopup="true" aria-expanded="false"><span class="ava" id="ava">{{ (user or "?")[:1] | upper }}</span><span class="wt"><span>当前管理员</span><b id="who">{{ user }}</b></span><svg class="chev" width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M3 4.5l3 3 3-3" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>
<div class="acts" id="acts">
<button id="titlebtn" type="button">修改标题</button>
<button id="userbtn" type="button">修改用户名</button>
<button id="pwbtn" type="button">修改密码</button>
<button id="tgbtn" type="button">Telegram 通知</button>
<form method="post" action="/logout"><button type="submit" class="logout">退出登录</button></form>
</div>
</div>
</header>
<section>
<div class="sect-h"><h2>节点</h2><span class="counts" id="nodeSum"></span><span class="grow"></span>
<div class="seg" id="nodeView"><button type="button" data-v="card">卡片</button><button type="button" data-v="list">精简</button></div></div>
<div id="ov"><div class="nodes"><div class="node skel" aria-hidden="true"><i class="sk w45 h20"></i><i class="sk w30"></i><i class="sk w80 h20"></i><i class="sk w60"></i></div><div class="node skel" aria-hidden="true"><i class="sk w45 h20"></i><i class="sk w30"></i><i class="sk w80 h20"></i><i class="sk w60"></i></div><div class="node skel" aria-hidden="true"><i class="sk w45 h20"></i><i class="sk w30"></i><i class="sk w80 h20"></i><i class="sk w60"></i></div><div class="node skel" aria-hidden="true"><i class="sk w45 h20"></i><i class="sk w30"></i><i class="sk w80 h20"></i><i class="sk w60"></i></div></div></div>
</section>
<div class="dhead">
<h2 id="title">节点详情</h2>
<div class="bar" style="margin:0">
<button id="reload" type="button">立即刷新</button>
<a class="btn" id="exportIps" href="#">导出 IP</a>
<a class="btn" id="exportSites" href="#">导出网站统计</a>
<a class="btn" id="exportTimeline" href="#">导出停留流水</a>
</div>
</div>
<div class="card">
<h2>当前在线 IP <span class="sub" id="liveN"></span></h2>
<div class="tw"><table><thead><tr><th>IP</th><th>归属地</th><th>运营商</th><th>网络类型</th><th>当前连接数</th></tr></thead>
<tbody id="live"><tr class="skrow" aria-hidden="true"><td colspan="5"><i class="sk w80"></i></td></tr><tr class="skrow" aria-hidden="true"><td colspan="5"><i class="sk w60"></i></td></tr><tr class="skrow" aria-hidden="true"><td colspan="5"><i class="sk w45"></i></td></tr></tbody></table></div>
</div>
<div class="card">
<h2>历史客户端 IP <span class="sub">点击 IP、访问网站数或次数,查看它访问过的网站和浏览轨迹</span></h2>
<div class="bar">
<input id="q" class="q" placeholder="搜索客户端 IP / 归属地 / 运营商 / 常访网站">
</div>
<div class="tw" style="max-height:420px;overflow:auto"><table><thead><tr>
<th>IP</th><th>归属地</th><th>运营商</th><th>网络类型</th><th>访问网站数</th><th>网站累计停留</th><th>常访网站(前3)</th><th>首次连接(北京时间)</th><th>最近连接(北京时间)</th><th>连接次数</th>
</tr></thead><tbody id="hist"><tr class="skrow" aria-hidden="true"><td colspan="10"><i class="sk w80"></i></td></tr><tr class="skrow" aria-hidden="true"><td colspan="10"><i class="sk w60"></i></td></tr><tr class="skrow" aria-hidden="true"><td colspan="10"><i class="sk w45"></i></td></tr></tbody></table></div>
</div>
<div class="card">
<div class="dh">
<div>
<h2>访问过的网站 <span class="sub" id="siteSub"></span></h2>
</div>
<div class="tabs" style="margin:0">
<button type="button" id="vMode1" class="act">按网站汇总排行</button>
<button type="button" id="vMode2">按时间轴 (浏览轨迹)</button>
</div>
</div>
<div class="chips" id="siteChips"></div>
<div class="chips" id="catChips"></div>
<div class="bar">
<input id="sq" class="q" placeholder="搜索网站域名 / 中文名 / 分类 / 子域名">
<select id="sip" title="按特定客户端 IP 过滤"><option value="">全部客户端 IP</option></select>
<select id="ssort" title="排序方式">
<option value="stay">按累计停留时长排序</option>
<option value="visits">按访问停留次数排序</option>
<option value="reqs">按请求连接次数排序</option>
<option value="last">按最近访问时间排序</option>
</select>
<button type="button" id="toggleAux" class="act" title="过滤 gstatic/googleapis/doubleclick/DNS 等背景辅助域名">仅看主站 (隐藏CDN/系统/广告)</button>
</div>
<div id="siteRankBox">
<div class="tw"><table><thead><tr>
<th>网站域名 / 名称</th><th>分类</th><th>累计停留时长</th><th>访问停留次数</th><th>平均每次停留</th><th>最长单次停留</th><th>连接请求数</th><th>访问 IP 数</th><th>子域名数</th><th>代表目标地址</th><th>首次访问(北京时间)</th><th>最近访问(北京时间)</th>
</tr></thead><tbody id="sitesTb"><tr class="skrow" aria-hidden="true"><td colspan="12"><i class="sk w80"></i></td></tr><tr class="skrow" aria-hidden="true"><td colspan="12"><i class="sk w60"></i></td></tr><tr class="skrow" aria-hidden="true"><td colspan="12"><i class="sk w45"></i></td></tr></tbody></table></div>
<p class="sub" style="margin:8px 0 0">提示:点击任意「网站域名」或「停留时长」可弹出查看该网站的每次进入/离开时间、停留时长、全部子域名与客户端 IP 明细。同一网站 5 分钟内的连续请求及活跃长连接自动归并为一次浏览停留;专属音视频流(如 googlevideo/bilivideo/nflxvideo/twimg 等)已自动归并入对应主站计算真实停留时长。</p>
</div>
<div id="siteTimeBox" hidden>
<div class="tw"><table><thead><tr>
<th>进入时间(开始访问)</th><th>离开/最后活跃时间</th><th>停留时长</th><th>访问网站</th><th>分类</th><th>客户端 IP</th><th>归属地 / 运营商</th><th>期间请求数</th><th>访问子域名明细</th><th>出站线路</th>
</tr></thead><tbody id="tlTb"></tbody></table></div>
<div class="bar" style="margin-top:10px"><button type="button" id="tlMore">加载更多</button><span class="sub" id="tlCount"></span></div>
</div>
</div>
<footer class="foot" id="foot"></footer>
</main>
<dialog id="dlg">
<div class="dh">
<div><h2 id="dtitle" style="margin:0"></h2><div class="sub" id="dsub"></div></div>
<button type="button" id="dclose">关闭</button>
</div>
<div class="chips" id="chips"></div>
<div class="tabs">
<button type="button" id="tab1" class="act">访问过的网站汇总(含停留时长)</button>
<button type="button" id="tab2">网站浏览时间轴轨迹</button>
<button type="button" id="tab3">TCP 连接会话(ss采样时长)</button>
<button type="button" id="tab4">每次连接请求明细</button>
</div>
<div id="p1">
<div class="scroll"><table><thead><tr>
<th>网站域名 / 名称</th><th>分类</th><th>累计停留时长</th><th>访问停留次数</th><th>平均每次停留</th><th>最长单次停留</th><th>请求数</th><th>首次访问</th><th>最近访问</th>
</tr></thead><tbody id="ipSites"></tbody></table></div>
<p class="sub">点击任意网站可查看该 IP 在该网站上的每次停留时间段与子域名明细。</p>
</div>
<div id="p2" hidden>
<div class="scroll"><table><thead><tr>
<th>进入时间</th><th>离开/最后活跃时间</th><th>停留时长</th><th>访问网站</th><th>分类</th><th>期间请求数</th><th>访问子域名明细</th><th>出站线路</th>
</tr></thead><tbody id="ipTl"></tbody></table></div>
<div class="bar" style="margin-top:10px"><button type="button" id="ipTlMore">加载更多</button><span class="sub" id="ipTlCount"></span></div>
</div>
<div id="p3" hidden>
<div class="scroll"><table><thead><tr><th>开始时间</th><th>结束时间</th><th>TCP 在线时长</th><th>客户端源端口</th><th>请求数</th><th>关联访问网站</th></tr></thead>
<tbody id="sess"></tbody></table></div>
<p class="sub">TCP 会话 = 客户端到服务器的底层连接,每 3 秒采样一次 ss。带"≥"的是服务重启前就已存在的连接。</p>
</div>
<div id="p4" hidden>
<div class="scroll"><table><thead><tr><th>时间</th><th>目标地址 (域名:端口)</th><th>所属网站</th><th>客户端源端口</th><th>协议</th><th>出站线路</th></tr></thead>
<tbody id="reqs"></tbody></table></div>
<div class="bar" style="margin-top:10px"><button type="button" id="more">加载更多</button><span class="sub" id="reqn"></span></div>
</div>
</dialog>
<dialog id="sitedlg">
<div class="dh">
<div><h2 id="sdtitle" style="margin:0"></h2><div class="sub" id="sdsub"></div></div>
<button type="button" id="sdclose">关闭</button>
</div>
<div class="chips" id="sdchips"></div>
<div class="tabs">
<button type="button" id="stab1" class="act">每次访问停留记录 (进入/离开/停留多久)</button>
<button type="button" id="stab2">包含的子域名与目标端口明细</button>
<button type="button" id="stab3">访问过该网站的客户端 IP</button>
<button type="button" id="stab4">逐条连接请求流水</button>
</div>
<div id="sp1">
<div class="scroll"><table><thead><tr>
<th>进入时间(开始访问)</th><th>离开/最后活跃时间</th><th>停留时长</th><th>客户端 IP</th><th>归属地 / 运营商</th><th>期间请求数</th><th>访问子域名明细</th><th>出站线路</th>
</tr></thead><tbody id="sdSess"></tbody></table></div>
<p class="sub">说明:同一客户端 IP 对该网站连续请求间隔不超过 5 分钟(或保持活跃 TCP 连接)视为一次连续停留。</p>
</div>
<div id="sp2" hidden>
<div class="scroll"><table><thead><tr>
<th>完整目标地址 (子域名:端口)</th><th>协议</th><th>出站线路</th><th>累计请求次数</th><th>首次访问(北京时间)</th><th>最近访问(北京时间)</th>
</tr></thead><tbody id="sdSubs"></tbody></table></div>
</div>
<div id="sp3" hidden>
<div class="scroll"><table><thead><tr>
<th>客户端 IP</th><th>归属地</th><th>运营商</th><th>网络类型</th><th>在该站累计停留</th><th>最长单次停留</th><th>访问停留次数</th><th>请求次数</th><th>首次访问</th><th>最近访问</th>
</tr></thead><tbody id="sdIps"></tbody></table></div>
</div>
<div id="sp4" hidden>
<div class="scroll"><table><thead><tr>
<th>精确时间</th><th>客户端 IP</th><th>源端口</th><th>完整目标地址 (host:port)</th><th>协议</th><th>出站线路</th>
</tr></thead><tbody id="sdReqs"></tbody></table></div>
<div class="bar" style="margin-top:10px"><button type="button" id="sdMore">加载更多</button><span class="sub" id="sdReqn"></span></div>
</div>
</dialog>
<dialog id="tgdlg">
<form class="tg" id="tgform" method="dialog">
<div class="tgh"><svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="12" fill="#2aabee"/><path d="M5.4 11.8l11.1-4.3c.5-.2 1 .1.8.9l-1.9 8.9c-.1.6-.5.8-1 .5l-2.9-2.1-1.4 1.3c-.2.2-.3.3-.6.3l.2-3 5.4-4.9c.2-.2 0-.3-.3-.1l-6.7 4.2-2.9-.9c-.6-.2-.6-.6.2-.8z" fill="#fff"/></svg><h2>Telegram 通知</h2><label class="sw" title="总开关"><input type="checkbox" id="tg_enabled"><span class="knob"></span><span class="swt">启用通知</span></label></div>
<p class="tgstate" id="tgState">还没有连接机器人</p>
<section class="tgs">
<h3>机器人</h3>
<label class="fld">Bot Token
<input id="tgToken" autocomplete="off" spellcheck="false" placeholder="例如 123456789:AAH…">
<span class="hint">在 Telegram 里找 <b>@BotFather</b>,发送 /newbot 按提示创建机器人,就会得到 Token</span></label>
<label class="fld">Chat ID
<span class="row"><input id="tg_chat" inputmode="numeric" autocomplete="off" placeholder="例如 123456789"><button type="button" id="tgDetect">自动获取</button></span>
<span class="hint">先在 Telegram 里给你的机器人发一条 /start,再点「自动获取」</span></label>
</section>
<section class="tgs">
<h3>通知哪些节点</h3>
<div class="seg" id="tgScope"><button type="button" data-v="all">全部节点</button><button type="button" data-v="some">指定节点</button></div>
<div class="tgnodes" id="tgNodes" hidden></div>
</section>
<section class="tgs">
<h3>通知内容</h3>
<div class="opts">
<label class="opt"><input type="checkbox" id="tg_ev_online"><span><b>节点上线</b><i>节点从无人连接变成有人连接时</i></span></label>
<label class="opt"><input type="checkbox" id="tg_ev_offline"><span><b>节点下线</b><i>无人连接持续 <input type="number" class="num" id="tg_offline_min" min="1" max="1440"> 分钟后</i></span></label>
<label class="opt"><input type="checkbox" id="tg_ev_new_ip"><span><b>新 IP 首次连接</b><i>附带归属地、运营商和网络类型</i></span></label>
<label class="opt"><input type="checkbox" id="tg_ev_share"><span><b>疑似共享</b><i>同一节点同时在线 IP 达到 <input type="number" class="num" id="tg_share_n" min="2" max="50"> 个(每小时最多提醒一次)</i></span></label>
<label class="opt"><input type="checkbox" id="tg_ev_daily"><span><b>每日日报</b><i>每天 <input type="time" class="tm" id="tg_daily_time"> 发送当天的在线、请求、常去网站和流量</i></span></label>
<label class="opt"><input type="checkbox" id="tg_ev_log"><span><b>访问日志中断</b><i>有人在线、但 30 分钟没有新日志时(面板会因此收不到数据)</i></span></label>
<label class="opt"><input type="checkbox" id="tg_ev_storage"><span><b>存储空间告警</b><i>用到上限的 85%,或发生自动清理时</i></span></label>
</div>
</section>
<section class="tgs">
<h3>免打扰</h3>
<div class="opts">
<label class="opt"><input type="checkbox" id="tg_quiet"><span><b>免打扰时段</b><i><input type="time" class="tm" id="tg_quiet_from"> 到 <input type="time" class="tm" id="tg_quiet_to"> 之间不推送(查询命令照常回复)</i></span></label>
</div>
</section>
<section class="tgs">
<h3>在 Telegram 里查询</h3>
<div class="opts">
<label class="opt"><input type="checkbox" id="tg_commands"><span><b>允许用命令查询</b><i>只回复上面这个 Chat ID,别人发命令不会理会</i></span></label>
</div>
<div class="cmds"><span><code>/menu</code>打开按钮菜单(推荐)</span><span><code>/status</code>所有节点当前在线情况</span><span><code>/node tim</code>节点的在线 IP 和今日常去网站</span><span><code>/ip 1.2.3.4</code>这个 IP 连过哪些节点、去过哪些网站</span><span><code>/today</code>今日概况</span><span><code>直接发 IP 或节点名</code>也能查</span></div>
</section>
<div class="msg" id="tgmsg"></div>
<div class="bar tgfoot"><button class="pri" type="submit">保存</button><button type="button" id="tgTest">发送测试消息</button><span class="grow"></span><button type="button" id="tgcancel">取消</button></div>
</form>
</dialog>
<dialog id="titledlg">
<form class="pw" id="titleform" method="dialog">
<h2>修改标题</h2>
<label>页面标题(留空则恢复默认)<input id="titleIn" maxlength="40" placeholder="数据流量分析面板"></label>
<div class="msg" id="titlemsg"></div>
<div class="bar"><button class="pri" type="submit">保存</button><button type="button" id="titlecancel">取消</button></div>
<p class="sub">会同时显示在页面顶部、浏览器标签页和登录页上。</p>
</form>
</dialog>
<dialog id="userdlg">
<form class="pw" id="userform" method="dialog">
<h2>修改用户名</h2>
<label>新用户名<input id="userIn" autocomplete="username" maxlength="32" required></label>
<label>当前密码<input id="userPw" type="password" autocomplete="current-password" required></label>
<div class="msg" id="usermsg"></div>
<div class="bar"><button class="pri" type="submit">保存</button><button type="button" id="usercancel">取消</button></div>
<p class="sub">修改后,其他已登录的设备需要用新用户名重新登录。</p>
</form>
</dialog>
<dialog id="pwdlg">
<form class="pw" id="pwform" method="dialog">
<h2>修改密码</h2>
<label>当前密码<input id="pw0" type="password" autocomplete="current-password" required></label>
<label>新密码<input id="pw1" type="password" autocomplete="new-password" required></label>
<label>再输一次新密码<input id="pw2" type="password" autocomplete="new-password" required></label>
<div class="msg" id="pwmsg"></div>
<div class="bar"><button class="pri" type="submit">保存</button><button type="button" id="pwcancel">取消</button></div>
<p class="sub">修改后,其他已登录的设备需要用新密码重新登录。</p>
</form>
</dialog>
<script>
const $ = s => document.querySelector(s);
const j = async (u, opt) => {
const r = await fetch(u, opt);
if (r.status === 401) { location.reload(); throw new Error('登录已失效'); }
if (!r.ok) throw new Error(r.status);
return r.json();
};
const NET_TIP = '依据 ip-api 的 mobile / hosting 标记推测;国内运营商的手机和宽带有时共用 IP 段,可能不准';
let current = null, overview = [], hideAux = true, curCat = '', viewMode = 1;
let tlState = {offset: 0, total: 0};
function emptyRow(tbody, n, text){
const tr = document.createElement('tr'), td = document.createElement('td');
td.colSpan = n; td.className = 'empty'; td.textContent = text;
tr.appendChild(td); tbody.appendChild(tr);
}
function cell(tr, text, cls, title){
const td = document.createElement('td');
td.textContent = text ?? '';
if (cls) td.className = cls;
if (title) td.title = title;
tr.appendChild(td);
return td;
}
function siteCell(tr, site, name, isAux, onClick){
const td = document.createElement('td');
const b = document.createElement('button');
b.type = 'button'; b.className = 'lnk';
b.textContent = site;
b.onclick = onClick;
td.appendChild(b);
if (name){
const s = document.createElement('span');
s.className = 'bdg ' + (isAux ? 'aux' : 'main');
s.textContent = name;
td.appendChild(s);
}
tr.appendChild(td);
}
function markSel(){
for (const el of $('#ov').querySelectorAll('[data-port]')) el.classList.toggle('sel', el.dataset.port === current);
}
function fmtDur(s){
s = Number(s || 0);
if (s <= 0) return '< 1 秒 (瞬时)';
if (s < 60) return s + ' 秒';
const m = Math.floor(s / 60), r = s % 60;
if (m < 60) return m + ' 分 ' + String(r).padStart(2, '0') + ' 秒';
const h = Math.floor(m / 60);
if (h < 24) return h + ' 小时 ' + String(m % 60).padStart(2, '0') + ' 分';
return Math.floor(h / 24) + ' 天 ' + (h % 24) + ' 小时';
}
function mk(tag, cls, text){
const e = document.createElement(tag);
if (cls) e.className = cls;
if (text !== undefined) e.textContent = text;
return e;
}
function kv(val, label){
const d = mk('div'); d.append(mk('b', '', val), mk('span', '', label)); return d;
}
function shortDur(s){
s = Number(s || 0);
if (s <= 0) return '0';
if (s < 60) return s + ' 秒';
if (s < 3600) return Math.floor(s / 60) + ' 分';
if (s < 86400) return (s / 3600).toFixed(1).replace(/\\.0$/, '') + ' 时';
return (s / 86400).toFixed(1).replace(/\\.0$/, '') + ' 天';
}
function ago(bj){
if (!bj) return '';
const t = Date.parse(bj.replace(' ', 'T') + '+08:00');
if (isNaN(t)) return bj;
const s = Math.max(0, (Date.now() - t) / 1000);
if (s < 90) return '刚刚';
if (s < 3600) return Math.round(s / 60) + ' 分钟前';
if (s < 86400) return Math.round(s / 3600) + ' 小时前';
if (s < 86400 * 30) return Math.round(s / 86400) + ' 天前';
return bj.slice(0, 10);
}
async function loadStorage(){
try {
const d = await j('/api/storage');
const f = $('#foot'); f.replaceChildren();
const used = d.db_bytes + d.log_bytes;
const pct = d.budget_bytes ? Math.min(100, Math.round(used / d.budget_bytes * 100)) : 0;
const head = mk('span', 'fh');
head.append(document.createTextNode('面板占用 '), mk('b', '', fmtBytes(used)), document.createTextNode(' / 上限 ' + fmtBytes(d.budget_bytes)));
const m = mk('span', 'meter' + (pct >= 85 ? ' hot' : '')); const bar = mk('i'); bar.style.width = Math.max(pct, 1) + '%'; m.appendChild(bar);
m.title = `已用额度 ${pct}%`;
const det = mk('span', 'fd', `数据库 ${fmtBytes(d.db_bytes)} · 访问日志 ${fmtBytes(d.log_bytes)} · 磁盘剩余 ${fmtBytes(d.disk_free)} / ${fmtBytes(d.disk_total)}`);
f.append(head, m, det);
let txt = `超过上限或磁盘剩余不足 ${fmtBytes(d.min_free_mb * 1048576)} 时自动清理:先删旧日志,再删最旧的明细,最后删最久没出现的 IP,保证不超过上限。平时明细保留 ${d.detail_days} 天、停留记录 ${d.site_days} 天。`;
if (d.last_trim) txt += ` 上次自动清理:${d.last_trim}(${d.last_trim_what})。`;
f.appendChild(mk('span', 'note', txt));
if (d.version){
const v = mk('a', 'ver', 'v' + d.version); v.href = d.project; v.target = '_blank'; v.rel = 'noopener';
f.appendChild(v);
}
} catch (e) {}
}
function setSync(state, text){
const u = $('#upd');
u.className = 'sync' + (state === 'err' ? ' err' : '');
const s = mk('span');
if (state === 'err') s.textContent = '刷新失败:' + text;
else s.append(document.createTextNode('已同步 '), mk('b', '', text));
u.replaceChildren(mk('i'), s);
}
function skeletonRows(tb, cols){
const ws = [80, 60, 45];
tb.replaceChildren();
for (const w of ws){
const tr = mk('tr', 'skrow'), td = mk('td'); td.colSpan = cols;
td.appendChild(mk('i', 'sk w' + w)); tr.appendChild(td); tb.appendChild(tr);
}
}
function selectNode(port){
if (port === current) return;
current = port; curCat = ''; $('#sip').value = ''; markSel();
// 立刻给出反馈:标题切过去,表格先显示占位,数据到了再填
const o = overview.find(r => r.port === current);
$('#title').textContent = (o && o.remark ? `${o.remark}  ` : '') + `端口 ${current}`;
skeletonRows($('#live'), 5); skeletonRows($('#hist'), 10); skeletonRows($('#sitesTb'), 12);
$('#liveN').textContent = ''; $('#siteSub').textContent = '';
loadDetail().catch(() => {});
}
const store = {
get(k, d){ try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } },
set(k, v){ try { localStorage.setItem(k, v); } catch (e) {} },
};
let nodeView = store.get('nodeView', 'card');
let idleOpen = store.get('idleOpen', '0') === '1';
function clickable(el, port){
el.dataset.port = port;
el.tabIndex = 0;
el.setAttribute('role', 'button');
el.onclick = () => selectNode(port);
el.onkeydown = e => { if (e.key === 'Enter' || e.key === ' '){ e.preventDefault(); selectNode(port); } };
}
function stateCls(r){
return (r.online_ips ? ' live' : '') + (r.enable === false ? ' off' : '');
}
function nodeCard(r){
const el = mk('div', 'node' + stateCls(r));
clickable(el, r.port);
const h = mk('div', 'nh');
h.appendChild(mk('span', 'nm', r.remark || '未命名'));
if (r.enable === false) h.appendChild(mk('span', 'flag', '已停用'));
if (r.sniffing === false){
const f = mk('span', 'flag w', '嗅探关');
f.title = '未开启域名嗅探:日志里只会记录 IP,开启后才能看到具体网站域名';
h.appendChild(f);
}
h.appendChild(portTag(r.port, 'pn'));
h.appendChild(protoBadge(r.protocol));
el.appendChild(h);
const st = mk('div', 'st');
const sb = mk('span', 'sbadge');
sb.append(mk('span', 'dot'), document.createTextNode(r.online_ips ? '在线' : '离线'));
st.appendChild(sb);
const sp = sparkline(r.spark);
if (r.online_ips){
for (const [n, u] of [[r.online_ips, 'IP'], [r.conns, '连接']]){
const s = mk('span', 'sstat'); s.append(mk('b', '', n), mk('span', '', u)); st.appendChild(s);
}
} else {
st.appendChild(mk('span', 'snote', r.last_seen ? '最近活跃 ' + ago(r.last_seen) : '日志里暂无连接记录'));
}
if (sp) st.appendChild(sp);
if (r.last_seen) st.title = '最近连接:' + r.last_seen;
el.appendChild(st);
const g = mk('div', 'kv');
if (r.hist_ips){
g.append(kv(r.hist_ips, '历史 IP'), kv(r.main_sites || 0, '访问网站'), kv(shortDur(r.total_stay_secs), '累计停留'));
if (traffic(r)){
const tk = kv(fmtBytes(traffic(r)), '累计流量');
tk.title = `上传 ${fmtBytes(r.up)} / 下载 ${fmtBytes(r.down)}(来自 x-ui 统计)`;
g.appendChild(tk);
}
} else {
g.append(kv(fmtBytes(traffic(r)), '累计流量'), kv(fmtBytes(r.up), '上传'), kv(fmtBytes(r.down), '下载'));
g.title = '流量来自 x-ui 统计;访问日志里还没有这个节点的连接记录';
}
g.style.setProperty('--n', g.children.length);
el.appendChild(g);
const tp = mk('div', 'tops');
const seenN = new Set();
for (const s of (r.top_sites || '').split(/,\\s*/)){
if (!s || /^IP 直接连接/.test(s)) continue;
const nm = s.replace(/^疑似\\s*/, '').replace(/\\s*·.*$/, '').replace(/\\s*[((].*$/, '').replace(/\\s*服务器$/, '').trim() || s;
if (seenN.has(nm)) continue;
seenN.add(nm);
const sp = mk('span', '', nm); sp.title = s; tp.appendChild(sp);
if (seenN.size >= 3) break;
}
if (!seenN.size) tp.appendChild(mk('span', 'none', r.hist_ips ? '暂无可识别的网站' : '没有访问网站的日志记录'));
el.appendChild(tp);
return el;
}
const PORT_SVG = '<svg width="12" height="12" viewBox="0 0 16 16" aria-hidden="true"><path d="M5 1.5v3M11 1.5v3" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M3.5 4.5h9v3a4.5 4.5 0 0 1-9 0z" fill="currentColor"/><path d="M8 12v2.5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';
function portTag(port, cls){
const s = mk('span', cls);
s.innerHTML = PORT_SVG;
s.appendChild(document.createTextNode(port));
s.title = '端口 ' + port;
return s;
}
const SVGNS = 'http://www.w3.org/2000/svg';
function svgEl(tag, attrs){ const e = document.createElementNS(SVGNS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; }
function sparkline(vals){
if (!vals || vals.length !== 7 || !vals.some(v => v > 0)) return null;
const W = 84, H = 24, P = 3, max = Math.max(...vals);
const x = i => P + i * (W - 2 * P) / 6, y = v => H - P - (v / max) * (H - 2 * P);
const s = svgEl('svg', {class: 'spark', width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: 'img'});
const pts = vals.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`);
s.appendChild(svgEl('line', {class: 'bs', x1: P, x2: W - P, y1: H - P + .5, y2: H - P + .5}));
s.appendChild(svgEl('path', {class: 'ar', d: `M${x(0)},${H - P} L${pts.join(' L')} L${x(6)},${H - P} Z`}));
s.appendChild(svgEl('path', {class: 'ln', d: 'M' + pts.join(' L')}));
s.appendChild(svgEl('circle', {class: 'pt', cx: x(6), cy: y(vals[6]), r: 2.6}));
const wk = ['日', '一', '二', '三', '四', '五', '六'];
const total = vals.reduce((a, b) => a + b, 0);
const lab = document.createElementNS(SVGNS, 'title'); lab.textContent = `近 7 天连接请求共 ${total.toLocaleString()} 次`; s.prepend(lab);
for (let i = 0; i < 7; i++){
const d = new Date(Date.now() + 8 * 3600e3 - (6 - i) * 86400e3);
const name = i === 6 ? '今天' : `${d.getUTCMonth() + 1}/${d.getUTCDate()} 周${wk[d.getUTCDay()]}`;
const cw = (W - 2 * P) / 6;
const rc = svgEl('rect', {x: Math.max(0, x(i) - cw / 2), y: 0, width: cw, height: H, rx: 2});
const tt = document.createElementNS(SVGNS, 'title'); tt.textContent = `${name}:${vals[i].toLocaleString()} 次请求`;
rc.appendChild(tt); s.appendChild(rc);
}
s.setAttribute('aria-label', lab.textContent);
return s;
}
function traffic(r){ return Number(r.up || 0) + Number(r.down || 0); }
function fmtBytes(n){
n = Number(n || 0);
const u = ['B', 'KB', 'MB', 'GB', 'TB'];
let i = 0;
while (n >= 1024 && i < u.length - 1){ n /= 1024; i++; }
return (i === 0 ? n : n.toFixed(n < 10 ? 2 : 1)) + ' ' + u[i];
}
function protoBadge(p){
const k = String(p || '').toLowerCase();
const names = {vmess: 'VMess', vless: 'VLESS', trojan: 'Trojan', shadowsocks: 'Shadowsocks', hysteria2: 'Hysteria2', hysteria: 'Hysteria', wireguard: 'WireGuard', socks: 'SOCKS', http: 'HTTP'};
return mk('span', 'proto ' + k.replace(/[^a-z0-9]/g, ''), names[k] || p || '?');
}
const GROUPS = [
['on', '在线', '当前有客户端连接的节点'],
['off', '离线', '现在没人连,但有连接记录或产生过流量的节点'],
['none', '未使用', '从未产生过流量、也没有连接记录的节点'],
];
function groupOf(r){ return r.online_ips ? 'on' : ((r.hist_ips || traffic(r)) ? 'off' : 'none'); }
function nodeGroups(list){
const g = {on: [], off: [], none: []};
for (const r of list) if (!r.deleted) g[groupOf(r)].push(r);
return g;
}
let delOpen = store.get('delOpen', '0') === '1';
function deletedGroup(list){
const dl = list.filter(r => r.deleted);
if (!dl.length) return null;
const d = mk('details', 'idle-grp del-grp');
if (delOpen || dl.some(r => r.port === current)) d.open = true;
d.ontoggle = () => { delOpen = d.open; store.set('delOpen', d.open ? '1' : '0'); };
d.appendChild(mk('summary', '', `已从 x-ui 删除的节点 ${dl.length} 个(历史数据仍保留)`));
const pl = mk('div', 'pills');
for (const r of dl){
const w = mk('span', 'delwrap');
const pill = nodePill(r);
pill.classList.add('deleted');
const x = mk('button', 'purge', '清除数据');
x.type = 'button';
x.title = '彻底删除这个端口在面板里的全部记录,不可恢复';
x.onclick = e => { e.stopPropagation(); purgeNode(r); };
w.append(pill, x);
pl.appendChild(w);
}
d.appendChild(pl);
return d;
}
async function purgeNode(r){
const name = (r.remark || '未命名') + '(端口 ' + r.port + ')';
if (!confirm(`确定要彻底清除「${name}」的全部历史数据吗?\n\n包括它的连接 IP、访问过的网站和停留记录,清除后无法恢复。`)) return;
try {
await postJSON('/api/purge', {port: r.port});
if (current === r.port) current = null;
await refresh();
} catch (e) { alert('清除失败:' + e.message); }
}
function nodePill(r){
const grp = groupOf(r);
const el = mk('div', 'pill' + (grp === 'on' ? ' live' : '') + (grp === 'none' ? ' unused' : '') + (r.enable === false ? ' off' : ''));
clickable(el, r.port);
el.title = `${r.remark || '未命名'} · ${r.protocol || ''} · 端口 ${r.port}`;
const pr = mk('span', 'pproto ' + String(r.protocol || '').toLowerCase().replace(/[^a-z0-9]/g, ''));
el.append(pr, mk('span', 'dot'), mk('b', '', (r.remark || '未命名') + (r.deleted ? '(已删除)' : '')), portTag(r.port, 'pp'));
if (r.deleted) el.title = `已从 x-ui 删除${r.deleted_seen ? ',最后一次在 x-ui 中看到:' + r.deleted_seen : ''}`;
const pm = mk('span', 'pm');
if (grp === 'on'){
pm.append(mk('strong', '', r.online_ips), document.createTextNode('IP'), mk('span', 'gap'), mk('strong', '', r.conns), document.createTextNode('连接'));
} else if (r.last_seen){
pm.textContent = ago(r.last_seen);
} else if (traffic(r)){
pm.textContent = fmtBytes(traffic(r));
}
if (pm.childNodes.length) el.appendChild(pm);
if (r.enable === false) el.appendChild(mk('span', 'flag', '已停用'));
return el;
}
function pillGroups(list){
const g = nodeGroups(list);
const wrap = mk('div');
for (const [key, label] of GROUPS){
if (!g[key].length) continue;
const row = mk('div', 'pgrp');
const ph = mk('div', 'ph');
ph.append(document.createTextNode(label), mk('b', '', g[key].length));
const pl = mk('div', 'pills');
for (const r of g[key]) pl.appendChild(nodePill(r));
row.append(ph, pl);
wrap.appendChild(row);
}
return wrap;
}
function sortedNodes(){
const rank = r => r.online_ips ? 0 : (r.hist_ips ? 1 : (traffic(r) ? 2 : 3));
return overview.map((r, i) => [r, i]).sort((a, b) => {
const ra = rank(a[0]), rb = rank(b[0]);
if (ra !== rb) return ra - rb;
if (ra === 0) return (b[0].conns || 0) - (a[0].conns || 0);
if (ra === 1) return String(b[0].last_seen || '').localeCompare(String(a[0].last_seen || ''));
if (ra === 2) return traffic(b[0]) - traffic(a[0]);
return a[1] - b[1];
}).map(x => x[0]);
}
function renderNodes(){
const box = $('#ov');
const oldRow = box.querySelector('.nodes');
const keepX = oldRow ? oldRow.scrollLeft : null;
box.replaceChildren();
for (const b of $('#nodeView').children) b.classList.toggle('act', b.dataset.v === nodeView);
if (!overview.length){
box.appendChild(mk('p', 'empty', '没有读到节点。请确认 x-ui 数据库路径是 /etc/x-ui/x-ui.db'));
return;
}
const list = sortedNodes();
if (nodeView === 'list'){
box.appendChild(pillGroups(list));
const dg = deletedGroup(list); if (dg) box.appendChild(dg);
} else {
const used = r => r.online_ips || r.hist_ips || traffic(r);
const active = list.filter(r => !r.deleted && used(r));
const idle = list.filter(r => !r.deleted && !used(r));
if (active.length){
const grid = mk('div', 'nodes');
for (const r of active) grid.appendChild(nodeCard(r));
box.appendChild(grid);
}
if (idle.length){
const d = mk('details', 'idle-grp');
if (idleOpen || !active.length || idle.some(r => r.port === current)) d.open = true;
d.ontoggle = () => { idleOpen = d.open; store.set('idleOpen', d.open ? '1' : '0'); };
d.appendChild(mk('summary', '', active.length ? `另外 ${idle.length} 个未使用的节点` : `${idle.length} 个节点都还没有使用过`));
const pl = mk('div', 'pills');
for (const r of idle) pl.appendChild(nodePill(r));
d.appendChild(pl);
box.appendChild(d);
}
const dg = deletedGroup(list); if (dg) box.appendChild(dg);
}
markSel();
const row = box.querySelector('.nodes');
if (row){
if (keepX !== null) row.scrollLeft = keepX;
else {
const sel = row.querySelector('.sel');
if (sel && row.scrollWidth > row.clientWidth) row.scrollLeft = sel.offsetLeft - row.offsetLeft - 12;
}
}
}
async function loadOverview(){
overview = await j('/api/overview');
if (current === null || !overview.some(r => r.port === current)){
const first = overview.find(r => r.online_ips > 0) || overview.find(r => r.hist_ips > 0) || overview[0];
current = first ? first.port : null;
}
const liveN = overview.filter(r => r.online_ips && !r.deleted).length;
const ns = $('#nodeSum'); ns.replaceChildren();
if (overview.length){
const g = nodeGroups(overview);
const all = mk('span', 'cnt all'); all.append(document.createTextNode('全部'), mk('b', '', overview.filter(r => !r.deleted).length)); all.title = 'x-ui 中的全部入站节点';
ns.append(all, mk('span', 'csep'));
for (const [key, label, tip] of GROUPS){
const c = mk('span', 'cnt ' + key);
c.append(mk('i'), document.createTextNode(label), mk('b', '', g[key].length));
c.title = tip; ns.appendChild(c);
}
}
renderNodes();
}
function updateExportLinks(){
if (!current) return;
const p = encodeURIComponent(current);
const ip = encodeURIComponent($('#sip').value || '');
const aux = hideAux ? '1' : '0';
$('#exportIps').href = `/api/export?port=${p}`;
$('#exportSites').href = `/api/export_sites?port=${p}&ip=${ip}&hide_aux=${aux}`;
$('#exportTimeline').href = `/api/export_timeline?port=${p}&ip=${ip}`;
}
async function loadSites(seq){
if (current === null) return;
const port = current;
updateExportLinks();
const p = encodeURIComponent(current);
const ip = encodeURIComponent($('#sip').value || '');
const q = encodeURIComponent($('#sq').value.trim());
const sort = encodeURIComponent($('#ssort').value);
const cat = encodeURIComponent(curCat);
const aux = hideAux ? '1' : '0';
const d = await j(`/api/sites?port=${p}&ip=${ip}&q=${q}&hide_aux=${aux}&cat=${cat}&sort=${sort}`);
if (port !== current || (seq !== undefined && seq !== detailSeq)) return;
const sum = d.summary;
$('#siteSub').textContent = `(主站 ${sum.main_sites} 个 · 辅助/CDN ${sum.aux_sites} 个 · 去重活跃浏览 ${fmtDur(sum.active_secs)})`;
const sc = $('#siteChips'); sc.replaceChildren();
const topChips = [
`当前显示 ${sum.shown_sites} 个网站`,
`去重活跃浏览时长 ${fmtDur(sum.active_secs)}`,
`各站累计停留总和 ${fmtDur(sum.total_stay_secs)}`,
`总访问停留 ${sum.total_visits} 次`,
`总请求 ${sum.total_reqs} 次`,
];
for (const t of topChips){
const s = document.createElement('span'); s.className = 'chip'; s.textContent = t; sc.appendChild(s);
}
const cc = $('#catChips'); cc.replaceChildren();
if (sum.categories && sum.categories.length){
const allChip = document.createElement('span');
allChip.className = 'chip click' + (curCat === '' ? ' act' : '');
allChip.textContent = '全部分类';
allChip.onclick = () => { curCat = ''; loadSites(); };
cc.appendChild(allChip);
for (const c of sum.categories){
const el = document.createElement('span');
el.className = 'chip click' + (curCat === c.cat ? ' act' : '');
el.textContent = `${c.cat} (${c.sites}) · ${fmtDur(c.stay_secs)}`;
el.onclick = () => { curCat = (curCat === c.cat ? '' : c.cat); loadSites(); };
cc.appendChild(el);
}
}
const tb = $('#sitesTb'); tb.replaceChildren();
if (!d.rows.length){
emptyRow(tb, 12, hideAux && sum.aux_sites > 0
? '当前过滤条件下没有主站记录(可点击上方「显示全部域名」查看 CDN/DNS 记录)'
: '还没有网站访问记录(开启日志后有人通过该端口访问网站即会出现)');
} else {
for (const r of d.rows){
const tr = document.createElement('tr');
const openFn = () => openSiteDetail(current, r.site, $('#sip').value || '');
siteCell(tr, r.site, r.name, r.is_aux, openFn);
cell(tr, r.category, r.is_aux ? 'mut' : '');
const tdStay = document.createElement('td');
const bStay = document.createElement('button');
bStay.type = 'button'; bStay.className = 'lnk';
bStay.textContent = fmtDur(r.stay_secs);
bStay.onclick = openFn;
tdStay.appendChild(bStay);
tr.appendChild(tdStay);
cell(tr, r.visit_cnt + ' 次');
cell(tr, fmtDur(r.avg_stay_secs), 'mut');
cell(tr, fmtDur(r.max_stay_secs), 'mut');
cell(tr, r.req_cnt);
cell(tr, r.ip_cnt);
cell(tr, r.sub_cnt);
cell(tr, r.sample_host, 'trunc mut', r.sample_host);
cell(tr, r.first_seen, 'mut');
cell(tr, r.last_seen, 'mut');
tb.appendChild(tr);
}
}
if (viewMode === 2) await loadPortTimeline(true);
}
async function loadPortTimeline(reset){
if (current === null) return;
if (reset){ tlState.offset = 0; $('#tlTb').replaceChildren(); }
const p = encodeURIComponent(current);
const ip = encodeURIComponent($('#sip').value || '');
const q = encodeURIComponent($('#sq').value.trim());
const aux = hideAux ? '1' : '0';
const d = await j(`/api/site_timeline?port=${p}&ip=${ip}&q=${q}&hide_aux=${aux}&offset=${tlState.offset}`);
const tb = $('#tlTb');
if (!d.rows.length && tlState.offset === 0){
emptyRow(tb, 10, '暂无符合条件的网站浏览时间轴记录');
}
for (const r of d.rows){
const tr = document.createElement('tr');
cell(tr, r.start);
cell(tr, r.live ? '正在访问中' : r.end, r.live ? 'on' : '');
cell(tr, fmtDur(r.stay_secs), r.stay_secs >= 60 ? 'on' : '');
siteCell(tr, r.site, r.name, r.is_aux, () => openSiteDetail(current, r.site, r.ip));
cell(tr, r.category, 'mut');
const tdIp = document.createElement('td');
const bIp = document.createElement('button');
bIp.type = 'button'; bIp.className = 'lnk'; bIp.textContent = r.ip;
bIp.onclick = () => openConn(current, r.ip);
tdIp.appendChild(bIp);
tr.appendChild(tdIp);
cell(tr, [r.loc, r.carrier].filter(Boolean).join(' · '), 'mut');
cell(tr, r.req_cnt);
cell(tr, r.hosts, 'trunc mut', r.hosts);
cell(tr, r.outbound, 'mut');
tb.appendChild(tr);
}
tlState.offset += d.rows.length;
tlState.total = d.total;
$('#tlCount').textContent = `已显示 ${tlState.offset} / ${d.total} 段浏览停留记录`;
$('#tlMore').hidden = tlState.offset >= d.total;
}
let detailSeq = 0;
async function loadDetail(){
if (current === null) return;
const seq = ++detailSeq, port = current;
const o = overview.find(r => r.port === current);
$('#title').textContent = (o && o.remark ? `${o.remark}  ` : '') + `端口 ${current}` + (o && o.deleted ? '(已从 x-ui 删除)' : '');
const p = encodeURIComponent(current);
const [live, hist] = await Promise.all([
j(`/api/live?port=${p}`),
j(`/api/ips?port=${p}&q=${encodeURIComponent($('#q').value.trim())}`),
loadSites(seq),
]);
if (seq !== detailSeq || port !== current) return;   // 期间已切到别的节点,丢弃旧结果
$('#liveN').textContent = `(${live.length} 个 IP)`;
// 更新客户端 IP 下拉筛选器
const selIp = $('#sip');
const prevIp = selIp.value;
if (!$('#q').value.trim()){
selIp.replaceChildren();
const opt0 = document.createElement('option');
opt0.value = ''; opt0.textContent = `全部客户端 IP (${hist.length})`;
selIp.appendChild(opt0);
for (const r of hist){
const opt = document.createElement('option');
opt.value = r.ip;
opt.textContent = `${r.ip} (${[r.loc, r.carrier].filter(Boolean).join(' ') || '未知'})`;
selIp.appendChild(opt);
}
if (hist.some(r => r.ip === prevIp)) selIp.value = prevIp;
}
// 渲染当前在线表
const ltb = $('#live'); ltb.replaceChildren();
if (!live.length) emptyRow(ltb, 5, '当前没有在线连接');
for (const r of live){
const tr = document.createElement('tr');
const tdIp = document.createElement('td');
const b = document.createElement('button');
b.type = 'button'; b.className = 'lnk'; b.textContent = r.ip;
b.onclick = () => openConn(current, r.ip);
tdIp.appendChild(b); tr.appendChild(tdIp);
cell(tr, r.loc); cell(tr, r.carrier, '', r.isp_raw); cell(tr, r.net, '', NET_TIP); cell(tr, r.conns, 'on');
ltb.appendChild(tr);
}
// 渲染历史连接 IP 表
const htb = $('#hist'); htb.replaceChildren();
if (!hist.length) emptyRow(htb, 10, '还没有记录(开启日志后有人连接才会出现)');
for (const r of hist){
const tr = document.createElement('tr');
const openIp = () => openConn(current, r.ip);
const tdIp = document.createElement('td');
const bIp = document.createElement('button');
bIp.type = 'button'; bIp.className = 'lnk'; bIp.textContent = r.ip;
bIp.onclick = openIp;
tdIp.appendChild(bIp); tr.appendChild(tdIp);
cell(tr, r.loc);
cell(tr, r.carrier, '', r.isp_raw);
cell(tr, r.net, '', NET_TIP);
const tdSc = document.createElement('td');
const bSc = document.createElement('button');
bSc.type = 'button'; bSc.className = 'lnk';
bSc.textContent = r.site_cnt ? `${r.main_site_cnt} 主站 / 共 ${r.site_cnt}` : '0';
bSc.onclick = openIp;
tdSc.appendChild(bSc); tr.appendChild(tdSc);
cell(tr, r.stay_secs ? fmtDur(r.stay_secs) : '-');
cell(tr, r.top_sites || '-', 'trunc mut', r.top_sites || '');
cell(tr, r.first_seen, 'mut');
cell(tr, r.last_seen, 'mut');
const tdCnt = document.createElement('td');
const bCnt = document.createElement('button');
bCnt.type = 'button'; bCnt.className = 'lnk'; bCnt.textContent = r.cnt;
bCnt.onclick = openIp;
tdCnt.appendChild(bCnt); tr.appendChild(tdCnt);
htb.appendChild(tr);
}
}
let lastStorage = 0;
async function refresh(){
$('#upd').classList.add('busy');
if (Date.now() - lastStorage > 60000){ lastStorage = Date.now(); loadStorage(); }
try {
if (current === null){ await loadOverview(); await loadDetail(); }   // 首次:先拿到节点列表才知道看哪个
else await Promise.all([loadOverview(), loadDetail()]);
setSync('ok', new Date().toLocaleTimeString('zh-CN', {hour12: false}));
} catch (e) { setSync('err', e.message); }
}
/* ---------- 视图切换与筛选控件 ---------- */
$('#vMode1').onclick = () => {
viewMode = 1;
$('#vMode1').classList.add('act'); $('#vMode2').classList.remove('act');
$('#siteRankBox').hidden = false; $('#siteTimeBox').hidden = true;
};
$('#vMode2').onclick = () => {
viewMode = 2;
$('#vMode2').classList.add('act'); $('#vMode1').classList.remove('act');
$('#siteRankBox').hidden = true; $('#siteTimeBox').hidden = false;
loadPortTimeline(true).catch(() => {});
};
$('#toggleAux').onclick = () => {
hideAux = !hideAux;
$('#toggleAux').classList.toggle('act', hideAux);
$('#toggleAux').textContent = hideAux ? '仅看主站 (隐藏CDN/系统/广告)' : '显示全部域名 (含CDN/系统/广告)';
loadSites().catch(() => {});
};
$('#sip').onchange = () => loadSites().catch(() => {});
$('#ssort').onchange = () => loadSites().catch(() => {});
$('#tlMore').onclick = () => loadPortTimeline(false).catch(() => {});
let stTimer;
$('#sq').oninput = () => { clearTimeout(stTimer); stTimer = setTimeout(() => loadSites().catch(() => {}), 250); };
/* ---------- 单个网站深度详情弹窗 ---------- */
let sdState = {port: null, site: null, ip: '', offset: 0, total: 0};
function showSiteTab(n){
for (let i = 1; i <= 4; i++){
$('#sp' + i).hidden = i !== n;
$('#stab' + i).classList.toggle('act', i === n);
}
if (n === 4 && sdState.offset === 0) loadSiteReqs(true);
}
async function openSiteDetail(port, site, ipFilter=''){
sdState = {port, site, ip: ipFilter || '', offset: 0, total: 0};
$('#sdtitle').textContent = `${site} · 端口 ${port}` + (ipFilter ? ` (IP: ${ipFilter})` : '');
$('#sdsub').textContent = '加载中…';
$('#sdchips').replaceChildren(); $('#sdSess').replaceChildren();
$('#sdSubs').replaceChildren(); $('#sdIps').replaceChildren(); $('#sdReqs').replaceChildren();
showSiteTab(1);
if (!$('#sitedlg').open) $('#sitedlg').showModal();
try {
const u = `/api/site_detail?port=${encodeURIComponent(port)}&site=${encodeURIComponent(site)}&ip=${encodeURIComponent(sdState.ip)}`;
const d = await j(u);
$('#sdtitle').textContent = (d.name ? `${d.name} (${d.site})` : d.site) + ` · 端口 ${port}` + (d.ip_filter ? ` · IP ${d.ip_filter}` : '');
$('#sdsub').textContent = `分类: ${d.category} · 首次访问: ${d.first_seen || '-'} · 最近访问: ${d.last_seen || '-'}`;
const chips = [
`累计停留时长 ${fmtDur(d.stay_secs)}`,
`去重活跃时长 ${fmtDur(d.active_secs)}`,
`访问停留 ${d.visit_cnt} 次`,
`平均每次停留 ${fmtDur(d.avg_stay_secs)}`,
`最长单次停留 ${fmtDur(d.max_stay_secs)}`,
`总请求 ${d.req_cnt} 次`,
`访问客户端 IP ${d.ip_cnt} 个`,
`包含子域名/端口 ${d.sub_cnt} 个`,
];
const cb = $('#sdchips');
for (const t of chips){ const s = document.createElement('span'); s.className = 'chip'; s.textContent = t; cb.appendChild(s); }
// Tab 1: 每次停留会话
const tb1 = $('#sdSess');
if (!d.sessions.length) emptyRow(tb1, 8, '暂无会话明细');
for (const s of d.sessions){
const tr = document.createElement('tr');
cell(tr, s.start);
cell(tr, s.live ? '正在访问中' : s.end, s.live ? 'on' : '');
cell(tr, fmtDur(s.stay_secs), s.stay_secs >= 60 ? 'on' : '');
const tdIp = document.createElement('td');
const bIp = document.createElement('button');
bIp.type = 'button'; bIp.className = 'lnk'; bIp.textContent = s.ip;
bIp.onclick = () => { $('#sitedlg').close(); openConn(port, s.ip); };
tdIp.appendChild(bIp); tr.appendChild(tdIp);
cell(tr, [s.loc, s.carrier].filter(Boolean).join(' · '), 'mut');
cell(tr, s.req_cnt);
cell(tr, s.hosts, 'trunc mut', s.hosts);
cell(tr, s.outbound, 'mut');
tb1.appendChild(tr);
}
// Tab 2: 子域名明细
const tb2 = $('#sdSubs');
if (!d.subdomains.length) emptyRow(tb2, 6, '暂无子域名记录');
for (const sub of d.subdomains){
const tr = document.createElement('tr');
cell(tr, sub.target);
cell(tr, sub.net);
cell(tr, sub.outbound);
cell(tr, sub.req_cnt);
cell(tr, sub.first_seen, 'mut');
cell(tr, sub.last_seen, 'mut');
tb2.appendChild(tr);
}
// Tab 3: 访问过该网站的客户端 IP
const tb3 = $('#sdIps');
if (!d.ips.length) emptyRow(tb3, 10, '暂无 IP 记录');
for (const r of d.ips){
const tr = document.createElement('tr');
const tdIp = document.createElement('td');
const bIp = document.createElement('button');
bIp.type = 'button'; bIp.className = 'lnk'; bIp.textContent = r.ip;
bIp.onclick = () => { $('#sitedlg').close(); openConn(port, r.ip); };
tdIp.appendChild(bIp); tr.appendChild(tdIp);
cell(tr, r.loc);
cell(tr, r.carrier);
cell(tr, r.net);
cell(tr, fmtDur(r.stay_secs));
cell(tr, fmtDur(r.max_stay_secs), 'mut');
cell(tr, r.visit_cnt + ' 次');
cell(tr, r.req_cnt);
cell(tr, r.first_seen, 'mut');
cell(tr, r.last_seen, 'mut');
tb3.appendChild(tr);
}
} catch (e) { $('#sdsub').textContent = '加载失败:' + e.message; }
}
async function loadSiteReqs(reset){
if (reset){ sdState.offset = 0; $('#sdReqs').replaceChildren(); }
const u = `/api/site_requests?port=${encodeURIComponent(sdState.port)}&site=${encodeURIComponent(sdState.site)}&ip=${encodeURIComponent(sdState.ip)}&offset=${sdState.offset}`;
const d = await j(u);
const tb = $('#sdReqs');
if (!d.rows.length && sdState.offset === 0) emptyRow(tb, 6, '没有找到原始请求记录');
for (const r of d.rows){
const tr = document.createElement('tr');
cell(tr, r.time); cell(tr, r.ip); cell(tr, r.src_port);
cell(tr, r.target); cell(tr, r.net); cell(tr, r.outbound);
tb.appendChild(tr);
}
sdState.offset += d.rows.length; sdState.total = d.total;
$('#sdReqn').textContent = `已显示 ${sdState.offset} / ${d.total} 条`;
$('#sdMore').hidden = sdState.offset >= d.total;
}
$('#stab1').onclick = () => showSiteTab(1);
$('#stab2').onclick = () => showSiteTab(2);
$('#stab3').onclick = () => showSiteTab(3);
$('#stab4').onclick = () => showSiteTab(4);
$('#sdMore').onclick = () => loadSiteReqs(false).catch(() => {});
$('#sdclose').onclick = () => $('#sitedlg').close();
/* ---------- 客户端 IP 连接明细弹窗 ---------- */
let conn = {port: null, ip: null, offset: 0, total: 0, tlOffset: 0, tlTotal: 0};
function showTab(n){
for (let i = 1; i <= 4; i++){
$('#p' + i).hidden = i !== n;
$('#tab' + i).classList.toggle('act', i === n);
}
if (n === 2 && conn.tlOffset === 0) loadIpTimeline(true);
if (n === 4 && conn.offset === 0) loadReqs(true);
}
async function openConn(port, ip){
conn = {port, ip, offset: 0, total: 0, tlOffset: 0, tlTotal: 0};
$('#dtitle').textContent = `${ip} · 端口 ${port}`;
$('#dsub').textContent = '加载中…';
$('#chips').replaceChildren(); $('#ipSites').replaceChildren();
$('#ipTl').replaceChildren(); $('#sess').replaceChildren(); $('#reqs').replaceChildren();
showTab(1);
if (!$('#dlg').open) $('#dlg').showModal();
try {
const d = await j(`/api/detail?port=${encodeURIComponent(port)}&ip=${encodeURIComponent(ip)}`);
$('#dsub').textContent = [d.loc, d.carrier, d.net].filter(Boolean).join(' · ');
const ss = d.site_summary || {};
const chips = [
`访问网站 ${ss.main_sites || 0} 主站 / 共 ${ss.total_sites || 0} 个`,
`去重活跃浏览 ${fmtDur(ss.active_secs || 0)}`,
`网站累计停留 ${fmtDur(ss.total_stay_secs || 0)}`,
`TCP 连接会话 ${d.session_count} 个 (在线累计 ${fmtDur(d.total_seconds)})`,
`总连接请求 ${d.total_cnt} 次`,
];
const cb = $('#chips');
for (const t of chips){ const s = document.createElement('span'); s.className = 'chip'; s.textContent = t; cb.appendChild(s); }
// Tab 1: 该 IP 访问过的网站汇总
const stb = $('#ipSites');
if (!d.sites || !d.sites.length){
emptyRow(stb, 9, '暂无该 IP 的网站访问记录');
} else {
for (const r of d.sites){
const tr = document.createElement('tr');
siteCell(tr, r.site, r.name, r.is_aux, () => openSiteDetail(port, r.site, ip));
cell(tr, r.category, r.is_aux ? 'mut' : '');
cell(tr, fmtDur(r.stay_secs));
cell(tr, r.visit_cnt + ' 次');
cell(tr, fmtDur(r.avg_stay_secs), 'mut');
cell(tr, fmtDur(r.max_stay_secs), 'mut');
cell(tr, r.req_cnt);
cell(tr, r.first_seen, 'mut');
cell(tr, r.last_seen, 'mut');
stb.appendChild(tr);
}
}
// Tab 3: TCP 会话
const tb = $('#sess'); tb.replaceChildren();
if (!d.sessions.length) emptyRow(tb, 6, '暂无 TCP 会话记录');
for (const s of d.sessions){
const tr = document.createElement('tr');
cell(tr, s.start);
cell(tr, s.open ? '在线中' : s.end, s.open ? 'on' : '');
cell(tr, (s.approx ? '≥ ' : '') + fmtDur(s.seconds));
cell(tr, s.src_port);
cell(tr, s.reqs);
cell(tr, s.sites || '-', 'trunc mut', s.sites || '');
tb.appendChild(tr);
}
} catch (e) { $('#dsub').textContent = '加载失败:' + e.message; }
}
async function loadIpTimeline(reset){
if (reset){ conn.tlOffset = 0; $('#ipTl').replaceChildren(); }
const d = await j(`/api/site_timeline?port=${encodeURIComponent(conn.port)}&ip=${encodeURIComponent(conn.ip)}&offset=${conn.tlOffset}`);
const tb = $('#ipTl');
if (!d.rows.length && conn.tlOffset === 0) emptyRow(tb, 8, '暂无浏览轨迹记录');
for (const r of d.rows){
const tr = document.createElement('tr');
cell(tr, r.start);
cell(tr, r.live ? '正在访问中' : r.end, r.live ? 'on' : '');
cell(tr, fmtDur(r.stay_secs), r.stay_secs >= 60 ? 'on' : '');
siteCell(tr, r.site, r.name, r.is_aux, () => openSiteDetail(conn.port, r.site, conn.ip));
cell(tr, r.category, 'mut');
cell(tr, r.req_cnt);
cell(tr, r.hosts, 'trunc mut', r.hosts);
cell(tr, r.outbound, 'mut');
tb.appendChild(tr);
}
conn.tlOffset += d.rows.length; conn.tlTotal = d.total;
$('#ipTlCount').textContent = `已显示 ${conn.tlOffset} / ${d.total} 段浏览停留`;
$('#ipTlMore').hidden = conn.tlOffset >= d.total;
}
async function loadReqs(reset){
if (reset){ conn.offset = 0; $('#reqs').replaceChildren(); }
const d = await j(`/api/requests?port=${encodeURIComponent(conn.port)}&ip=${encodeURIComponent(conn.ip)}&offset=${conn.offset}`);
const tb = $('#reqs');
if (!d.rows.length && conn.offset === 0) emptyRow(tb, 6, '没有记录');
for (const r of d.rows){
const tr = document.createElement('tr');
cell(tr, r.time);
cell(tr, r.target);
cell(tr, r.site + (r.site_name ? ` (${r.site_name})` : ''), 'mut');
cell(tr, r.src_port);
cell(tr, r.net);
cell(tr, r.outbound);
tb.appendChild(tr);
}
conn.offset += d.rows.length; conn.total = d.total;
$('#reqn').textContent = `已显示 ${conn.offset} / ${d.total} 条`;
$('#more').hidden = conn.offset >= d.total;
}
$('#tab1').onclick = () => showTab(1);
$('#tab2').onclick = () => showTab(2);
$('#tab3').onclick = () => showTab(3);
$('#tab4').onclick = () => showTab(4);
$('#ipTlMore').onclick = () => loadIpTimeline(false).catch(() => {});
$('#more').onclick = () => loadReqs(false).catch(() => {});
$('#dclose').onclick = () => $('#dlg').close();
/* ---------- 修改密码 ---------- */
function pwMsg(t, cls){ const m = $('#pwmsg'); m.textContent = t; m.className = 'msg ' + (cls || ''); }
$('#pwbtn').onclick = () => { $('#pwform').reset(); pwMsg(''); $('#pwdlg').showModal(); };
$('#pwcancel').onclick = () => $('#pwdlg').close();
$('#pwform').onsubmit = async ev => {
ev.preventDefault();
const a = $('#pw0').value, b = $('#pw1').value, c = $('#pw2').value;
if (b !== c) return pwMsg('两次输入的新密码不一致', 'e');
if (!b) return pwMsg('新密码不能为空', 'e');
try {
const r = await fetch('/api/password', {method: 'POST', headers: {'Content-Type': 'application/json'},
body: JSON.stringify({old: a, new: b})});
const d = await r.json().catch(() => ({}));
if (!r.ok) return pwMsg(d.error || ('修改失败(' + r.status + ')'), 'e');
pwMsg('密码已修改', 'o');
setTimeout(() => $('#pwdlg').close(), 1200);
} catch (e) { pwMsg('网络错误:' + e.message, 'e'); }
};
function setMsg(id, t, cls){ const m = $(id); m.textContent = t; m.className = 'msg ' + (cls || ''); }
async function postJSON(url, body){
const r = await fetch(url, {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(body)});
const d = await r.json().catch(() => ({}));
if (!r.ok) throw new Error(d.error || ('保存失败(' + r.status + ')'));
return d;
}
$('#titlebtn').onclick = () => { $('#titleIn').value = $('#siteTitle').textContent; setMsg('#titlemsg', ''); $('#titledlg').showModal(); $('#titleIn').select(); };
$('#titlecancel').onclick = () => $('#titledlg').close();
$('#titleform').onsubmit = async ev => {
ev.preventDefault();
try {
const d = await postJSON('/api/title', {title: $('#titleIn').value});
$('#siteTitle').textContent = d.title; document.title = d.title;
setMsg('#titlemsg', '标题已保存', 'o');
setTimeout(() => $('#titledlg').close(), 900);
} catch (e) { setMsg('#titlemsg', e.message, 'e'); }
};
$('#userbtn').onclick = () => { $('#userform').reset(); $('#userIn').value = $('#who').textContent; setMsg('#usermsg', ''); $('#userdlg').showModal(); $('#userIn').select(); };
$('#usercancel').onclick = () => $('#userdlg').close();
$('#userform').onsubmit = async ev => {
ev.preventDefault();
const u = $('#userIn').value.trim();
if (!/^[A-Za-z0-9_.@-]{2,32}$/.test(u)) return setMsg('#usermsg', '用户名需 2–32 位,只能用字母、数字和 _ . @ -', 'e');
try {
const d = await postJSON('/api/username', {user: u, password: $('#userPw').value});
$('#who').textContent = d.user; $('#ava').textContent = d.user.slice(0, 1).toUpperCase();
setMsg('#usermsg', '用户名已修改,下次请用「' + d.user + '」登录', 'o');
setTimeout(() => $('#userdlg').close(), 1600);
} catch (e) { setMsg('#usermsg', e.message, 'e'); }
};
const THEME_ICON = {
auto: '<svg width="17" height="17" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="6.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10 3.5a6.5 6.5 0 0 1 0 13z" fill="currentColor"/></svg>',
light: '<svg width="17" height="17" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="3.6" fill="currentColor"/><g stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M10 1.8v2M10 16.2v2M1.8 10h2M16.2 10h2M4.2 4.2l1.4 1.4M14.4 14.4l1.4 1.4M4.2 15.8l1.4-1.4M14.4 5.6l1.4-1.4"/></g></svg>',
dark: '<svg width="17" height="17" viewBox="0 0 20 20" aria-hidden="true"><path d="M16.5 12.6A7 7 0 0 1 7.4 3.5a7 7 0 1 0 9.1 9.1z" fill="currentColor"/></svg>',
};
const THEME_NAME = {auto: '跟随系统', light: '浅色', dark: '深色'};
const META_TC = [...document.querySelectorAll('meta[name=theme-color]')].map(m => [m, m.getAttribute('media'), m.content]);
function applyTheme(mode){
const root = document.documentElement;
if (mode === 'auto') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', mode);
for (const [m, media, content] of META_TC){
if (mode === 'auto'){ m.setAttribute('media', media); m.content = content; }
else { m.removeAttribute('media'); m.content = mode === 'dark' ? '#0d131a' : '#edf1f5'; }
}
const b = $('#themeBtn');
b.innerHTML = THEME_ICON[mode];
b.title = '外观:' + THEME_NAME[mode] + '(点击切换)';
}
let themeMode = store.get('theme', 'auto');
if (!THEME_ICON[themeMode]) themeMode = 'auto';
applyTheme(themeMode);
$('#themeBtn').onclick = () => {
themeMode = {auto: 'light', light: 'dark', dark: 'auto'}[themeMode];
store.set('theme', themeMode); applyTheme(themeMode);
};
$('#acctBtn').onclick = e => {
if (!matchMedia('(max-width:900px)').matches) return;
e.stopPropagation();
const open = $('#top').classList.toggle('open');
$('#acctBtn').setAttribute('aria-expanded', open ? 'true' : 'false');
};
document.addEventListener('click', e => {
if ($('#top').classList.contains('open') && !$('#acts').contains(e.target)) $('#top').classList.remove('open');
});
for (const b of $('#acts').querySelectorAll('button')) b.addEventListener('click', () => $('#top').classList.remove('open'));
document.addEventListener('keydown', e => { if (e.key === 'Escape') $('#top').classList.remove('open'); });
/* ---------- Telegram 通知设置 ---------- */
const TG_BOOL = ['enabled', 'commands', 'ev_online', 'ev_offline', 'ev_new_ip', 'ev_share', 'ev_daily', 'ev_log', 'ev_storage', 'quiet'];
const TG_VAL = ['offline_min', 'share_n', 'daily_time', 'quiet_from', 'quiet_to'];
let tgScope = 'all';
function tgMsg(t, cls){ setMsg('#tgmsg', t, cls); }
function tgSetScope(v){
tgScope = v;
for (const b of $('#tgScope').children) b.classList.toggle('act', b.dataset.v === v);
$('#tgNodes').hidden = v !== 'some';
}
function tgState(d){
const s = $('#tgState');
if (d.bot && d.chat_id){ s.textContent = `已连接机器人 ${d.bot},发送到 Chat ID ${d.chat_id}` + (d.enabled ? '' : '(通知总开关未打开)'); s.className = 'tgstate ok'; }
else if (d.bot){ s.textContent = `已连接机器人 ${d.bot},还差 Chat ID`; s.className = 'tgstate'; }
else { s.textContent = '还没有连接机器人'; s.className = 'tgstate'; }
}
async function openTg(){
tgMsg('');
let d;
try { d = await j('/api/tg'); } catch (e) { return alert('读取设置失败:' + e.message); }
for (const k of TG_BOOL) $('#tg_' + k).checked = !!d[k];
for (const k of TG_VAL) $('#tg_' + k).value = d[k];
$('#tg_chat').value = d.chat_id || '';
$('#tgToken').value = '';
$('#tgToken').placeholder = d.token_set ? `已保存(${d.token_hint}),不改就留空` : '例如 123456789:AAH…';
tgState(d);
const box = $('#tgNodes'); box.replaceChildren();
const sel = new Set(d.nodes || []);
for (const r of overview.filter(r => !r.deleted)){
const lab = mk('label', 'tgnode' + (sel.has(r.port) ? ' on' : ''));
const cb = mk('input'); cb.type = 'checkbox'; cb.value = r.port; cb.checked = sel.has(r.port);
cb.onchange = () => lab.classList.toggle('on', cb.checked);
lab.append(cb, document.createTextNode(r.remark || '未命名'), mk('small', '', r.port));
box.appendChild(lab);
}
tgSetScope(sel.size ? 'some' : 'all');
$('#tgdlg').showModal();
}
function tgCollect(){
const d = {};
for (const k of TG_BOOL) d[k] = $('#tg_' + k).checked;
for (const k of TG_VAL) d[k] = $('#tg_' + k).value;
d.chat_id = $('#tg_chat').value.trim();
const tok = $('#tgToken').value.trim();
if (tok) d.token = tok;
d.nodes = tgScope === 'some' ? [...$('#tgNodes').querySelectorAll('input:checked')].map(c => c.value) : [];
return d;
}
$('#tgbtn').onclick = openTg;
$('#tgcancel').onclick = () => $('#tgdlg').close();
for (const b of $('#tgScope').children) b.onclick = () => tgSetScope(b.dataset.v);
$('#tgDetect').onclick = async () => {
tgMsg('正在获取…');
try {
const d = await postJSON('/api/tg/detect', {token: $('#tgToken').value.trim()});
$('#tg_chat').value = d.chat_id;
tgMsg(`已获取:${d.name || ''}(${d.chat_id}),记得点「保存」`, 'o');
} catch (e) { tgMsg(e.message, 'e'); }
};
$('#tgTest').onclick = async () => {
tgMsg('正在发送…');
try { await postJSON('/api/tg/test', tgCollect()); tgMsg('已发送,请到 Telegram 查看', 'o'); }
catch (e) { tgMsg(e.message, 'e'); }
};
$('#tgform').onsubmit = async ev => {
ev.preventDefault();
const d = tgCollect();
if (tgScope === 'some' && !d.nodes.length) return tgMsg('选了「指定节点」,至少要勾一个节点', 'e');
tgMsg('正在保存…');
try {
const r = await postJSON('/api/tg', d);
tgMsg('已保存' + (d.enabled ? ',通知已启用' : ''), 'o');
setTimeout(() => $('#tgdlg').close(), 900);
} catch (e) { tgMsg(e.message, 'e'); }
};
$('#reload').onclick = refresh;
let t; $('#q').oninput = () => { clearTimeout(t); t = setTimeout(() => loadDetail().catch(() => {}), 250); };
refresh();
for (const b of $('#nodeView').children) b.onclick = () => { nodeView = b.dataset.v; store.set('nodeView', nodeView); renderNodes(); };
setInterval(() => { if (!document.hidden) refresh(); }, 10000);
</script></body></html>"""

# ---------------------------------------------------------------- 启动
# ---------------------------------------------------------------- Telegram 通知与查询
TG_API_BASE = os.environ.get("TG_API_BASE", "https://api.telegram.org")
TG_DEFAULT = {
    "enabled": False, "token": "", "chat_id": "", "nodes": [], "commands": True,
    "ev_online": True, "ev_offline": False, "offline_min": 10,
    "ev_new_ip": True, "ev_share": True, "share_n": 3,
    "ev_daily": True, "daily_time": "09:00",
    "ev_log": True, "ev_storage": True,
    "quiet": False, "quiet_from": "23:00", "quiet_to": "08:00",
}
_tg_lock = threading.Lock()
_tg_seen_chats = {}          # chat_id -> (名字, 时间):给「自动获取 Chat ID」用
_tg_bot_name = {}            # token -> @用户名

def tg_cfg():
    d = dict(TG_DEFAULT)
    d.update(load_settings().get("tg") or {})
    return d

def tg_api(token, method, params=None, timeout=15):
    req = urllib.request.Request(
        f"{TG_API_BASE}/bot{token}/{method}", data=json.dumps(params or {}).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except Exception:
            return {"ok": False, "description": f"HTTP {e.code}"}
    except Exception as e:  # noqa
        return {"ok": False, "description": f"连不上 Telegram:{e}"}

def tg_bot_name(token):
    if not token:
        return ""
    if token not in _tg_bot_name:
        r = tg_api(token, "getMe", timeout=10)
        if not r.get("ok"):
            return ""
        _tg_bot_name[token] = "@" + r["result"].get("username", "")
    return _tg_bot_name[token]

def _hm(s, default):
    try:
        h, m = (int(x) for x in str(s).split(":"))
        return h * 60 + m
    except Exception:
        return default

def tg_in_quiet(cfg):
    if not cfg.get("quiet"):
        return False
    now = datetime.now(DISPLAY_TZ)
    cur = now.hour * 60 + now.minute
    a, b = _hm(cfg.get("quiet_from"), 23 * 60), _hm(cfg.get("quiet_to"), 8 * 60)
    return (a <= cur < b) if a <= b else (cur >= a or cur < b)

def tg_send(text, cfg=None, force=False, chat_id=None, token=None):
    """发一条 HTML 格式的消息;force=True 时忽略「是否启用」和免打扰(测试消息、命令回复用)"""
    cfg = cfg or tg_cfg()
    token = token or cfg.get("token")
    chat_id = chat_id or cfg.get("chat_id")
    if not token or not chat_id:
        return {"ok": False, "description": "还没有填写 Bot Token 或 Chat ID"}
    if not force and (not cfg.get("enabled") or tg_in_quiet(cfg)):
        return {"ok": False, "description": "通知未启用或处于免打扰时段"}
    with _tg_lock:
        r = tg_api(token, "sendMessage", {"chat_id": chat_id, "text": text[:4000], "parse_mode": "HTML",
                                          "disable_web_page_preview": True})
    if not r.get("ok"):
        print("telegram send error:", r.get("description"), file=sys.stderr)
    return r

def _esc(s):
    return (str(s if s is not None else "").replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def _node_names():
    names = {}
    try:
        con = db()
        names = {r[0]: r[1] for r in con.execute("SELECT port, remark FROM node_seen")}
        con.close()
    except Exception:
        pass
    for i in xui_inbounds():
        names[i["port"]] = i["remark"]
    return names

def _nolink(s):
    """阻止 Telegram 把 tencent-cloud.net 这类文字自动识别成链接(把点换成外观一样的「․」)"""
    return _esc(s).replace(".", "\u2024")

def _nlabel(port, names):
    nm = names.get(port) or ""
    return f"<b>{_esc(nm)}</b> <code>{port}</code>" if nm else f"<b>端口</b> <code>{port}</code>"

def _geo_short(con, ip):
    """浙江温州 · 电信 · 宽带"""
    r = con.execute("SELECT country, region, city, isp, org, asn, mobile, hosting, proxy FROM geo WHERE ip=?", (ip,)).fetchone()
    if not r:
        return "归属地查询中"
    country, region, city = r[0] or "", r[1] or "", r[2] or ""
    if country in ("中国", "China"):
        reg = re.sub(r"(省|市|壮族自治区|回族自治区|维吾尔自治区|自治区|特别行政区)$", "", region)
        cty = re.sub(r"市$", "", city)
        loc = reg + (cty if cty and cty != reg else "")
    else:
        loc = " ".join(x for x in (country, city) if x)
    car = carrier(r[3], r[4], r[5]).replace("中国", "", 1) if carrier(r[3], r[4], r[5]).startswith("中国") else carrier(r[3], r[4], r[5])
    net = {"宽带/固网": "宽带", "手机网络": "手机", "机房/云主机": "机房", "代理/VPN": "代理"}.get(net_kind(r[6], r[7], r[8]), "")
    return " · ".join(x for x in (loc, car, net) if x) or "未知"

def _geo_line(con, ip):
    return _geo_short(con, ip)

def _today_start():
    now = datetime.now(DISPLAY_TZ)
    return int(now.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())

def _top_sites(con, port=None, ip=None, since=0, n=3):
    q = "SELECT site, MAX(host), COUNT(*) c FROM req WHERE t >= ?"
    a = [since]
    if port:
        q += " AND port = ?"; a.append(port)
    if ip:
        q += " AND ip = ?"; a.append(ip)
    q += " GROUP BY site ORDER BY c DESC LIMIT 60"
    out, seen = [], set()
    for site, host, c in con.execute(q, a):
        if not site:
            continue
        name, _cat, aux = site_meta(site, host or "")
        if aux:
            continue
        label = (name or site).split("(")[0].split("(")[0].replace("疑似 ", "").split(" · ")[0].replace(" 服务器", "").strip() or site
        if label in seen:
            continue
        seen.add(label)
        out.append((label, c))
        if len(out) >= n:
            break
    return out

def _sites_line(tops, counts=False):
    return "  ·  ".join(f"{_nolink(n)}" + (f" <i>{c:,}</i>" if counts else "") for n, c in tops)

def _node_ports(names):
    """真正的节点端口(x-ui 里的),排除面板自己、x-ui 面板等其它端口"""
    cur = {i["port"] for i in xui_inbounds()}
    return cur or set(names)

def _short_ts(ts):
    s = fmt_ts(ts) if ts else ""
    return s[5:16] if s else ""

WEEK = "一二三四五六日"

def tg_report_text(ports_filter=None, title="今日概况"):
    names = _node_names()
    live = live_map()
    since = _today_start()
    con = db()
    stats = {r[0]: (r[1], r[2]) for r in con.execute(
        "SELECT port, COUNT(DISTINCT ip), COUNT(*) FROM req WHERE t >= ? GROUP BY port", (since,))}
    tot_ips = con.execute("SELECT COUNT(DISTINCT ip) FROM req WHERE t >= ?", (since,)).fetchone()[0]
    inb = {i["port"]: i for i in xui_inbounds()}
    traffic = {p: i.get("up", 0) + i.get("down", 0) for p, i in inb.items()}
    snap = {}
    row = con.execute("SELECT v FROM meta WHERE k='tg_traffic_snap'").fetchone()
    if row:
        try:
            snap = json.loads(row[0])
        except Exception:
            snap = {}
    nodes = _node_ports(names)
    ports = [p for p in nodes if not ports_filter or p in ports_filter]
    ports.sort(key=lambda p: (-len(live.get(p, {})), -(stats.get(p, (0, 0))[1]), names.get(p) or p))
    now = datetime.now(DISPLAY_TZ)
    total_req = sum(stats.get(p, (0, 0))[1] for p in ports)
    delta_all = sum(traffic[p] - snap[p] for p in ports if p in traffic and p in snap and traffic[p] >= snap[p])
    head = [f"📊 <b>{title}</b>", f"<i>{_esc(site_title())} · {now.strftime('%m/%d')} 周{WEEK[now.weekday()]} {now.strftime('%H:%M')}</i>", "",
            f"今日共 <b>{tot_ips}</b> 个 IP · <b>{total_req:,}</b> 次请求" + (f" · 流量 <b>+{_fmt_bytes(delta_all)}</b>" if snap and delta_all else "")]
    blocks, quiet = [], 0
    for p in ports:
        ips_today, reqs = stats.get(p, (0, 0))
        on = len(live.get(p, {}))
        if not ips_today and not on:
            quiet += 1
            continue
        delta = ""
        if p in traffic and p in snap and traffic[p] > snap[p]:
            delta = f" · +{_fmt_bytes(traffic[p] - snap[p])}"
        b = [("🟢 " if on else "⚪ ") + _nlabel(p, names) + (f"  <i>在线 {on} IP</i>" if on else ""),
             f"└ 今日 {ips_today} 个 IP · {reqs:,} 次请求{delta}"]
        tops = _top_sites(con, port=p, since=since)
        if tops:
            b.append(f"└ {_sites_line(tops)}")
        blocks.append("\n".join(b))
    con.close()
    body = "\n\n".join(blocks) if blocks else "<i>今天还没有任何节点有活动</i>"
    tail = f"\n\n<i>其余 {quiet} 个节点今天没有活动</i>" if quiet and blocks else ""
    return "\n".join(head) + "\n\n" + body + tail, traffic

def _fmt_bytes(n):
    n = float(n or 0)
    for u in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or u == "TB":
            return f"{n:.0f} {u}" if u == "B" else f"{n:.2f} {u}" if n < 10 else f"{n:.1f} {u}"
        n /= 1024

def _match_node(arg, names):
    arg = (arg or "").strip().lower()
    if not arg:
        return None
    if arg in names:
        return arg
    for p, n in names.items():
        if (n or "").lower() == arg:
            return p
    for p, n in names.items():
        if arg in (n or "").lower():
            return p
    return None

TG_HELP = ("💡 <b>使用帮助</b>\n\n"
           "<b>点按钮</b>\n"
           "主菜单里的按钮可以查看节点状态、今日概况、单个节点详情,以及开关各项通知。\n\n"
           "<b>直接发消息</b>\n"
           "<blockquote>发一个 IP,如 <code>203.0.113.10</code>\n查它的归属地、连过的节点、常去网站\n\n"
           "发节点名或端口,如 <code>tim</code>\n打开这个节点的详情</blockquote>\n"
           "<b>命令</b>\n"
           "/menu 主菜单  ·  /status 节点状态  ·  /today 今日概况")

TG_REPLY_KEYS = {"📡 状态": "st", "📊 今日": "td", "🛰 节点": "nl", "☰ 菜单": "m"}
TG_EVENTS = [("ev_online", "节点上线"), ("ev_offline", "节点下线"), ("ev_new_ip", "新 IP 连接"),
             ("ev_share", "疑似共享"), ("ev_daily", "每日日报"), ("ev_log", "日志中断"), ("ev_storage", "存储告警")]

def _btn(text, data):
    return {"text": text, "callback_data": data}

def _kb(*rows):
    return {"inline_keyboard": [list(r) for r in rows if r]}

def _reply_kb():
    keys = list(TG_REPLY_KEYS)
    return {"keyboard": [[{"text": k} for k in keys]],
            "resize_keyboard": True, "is_persistent": True, "input_field_placeholder": "发 IP 或节点名直接查询"}

NAV = [_btn("🏠 主菜单", "m")]

def tg_view(key):
    """按钮对应的页面 -> (文字, 按钮)"""
    names = _node_names()
    if key == "m":
        live = live_map()
        nodes = _node_ports(names)
        on = [p for p in nodes if live.get(p)]
        con = db()
        ips_today, req_today = con.execute("SELECT COUNT(DISTINCT ip), COUNT(*) FROM req WHERE t >= ?", (_today_start(),)).fetchone()
        con.close()
        now = datetime.now(DISPLAY_TZ)
        lines = [f"📊 <b>{_esc(site_title())}</b>",
                 f"<i>{now.strftime('%m/%d')} 周{WEEK[now.weekday()]} {now.strftime('%H:%M')} · 共 {len(nodes)} 个节点</i>", "",
                 f"🟢 在线 <b>{len(on)}</b>   ⚪ 离线 <b>{len(nodes) - len(on)}</b>",
                 f"今日 <b>{ips_today}</b> 个 IP · <b>{req_today:,}</b> 次请求"]
        if on:
            rows = []
            for p in sorted(on, key=lambda p: -len(live[p]))[:6]:
                rows.append(f"{_nlabel(p, names)}  {len(live[p])} IP · {sum(live[p].values())} 连接")
            lines += ["", "<blockquote>" + "\n".join(rows) + "</blockquote>"]
        lines += ([] if on else [""]) + ["<i>点下方按钮,或直接发 IP / 节点名查询</i>"]
        return "\n".join(lines), _kb([_btn("📡 节点状态", "st"), _btn("📊 今日概况", "td")],
                                     [_btn("🛰 节点详情", "nl"), _btn("🔎 查询 IP", "ip")],
                                     [_btn("🔔 通知设置", "set"), _btn("💡 使用帮助", "help")])
    if key == "st":
        return tg_handle_command("/status"), _kb([_btn("🔄 刷新", "st"), _btn("🛰 节点详情", "nl")], NAV)
    if key == "td":
        return tg_report_text()[0], _kb([_btn("🔄 刷新", "td"), _btn("🛰 节点详情", "nl")], NAV)
    if key == "nl":
        live = live_map()
        nodes = _node_ports(names)
        ports = sorted(nodes, key=lambda p: (-len(live.get(p, {})), (names.get(p) or p).lower()))
        rows, row = [], []
        for p in ports:
            l = live.get(p)
            label = f"🟢 {(names.get(p) or p)[:12]} · {len(l)}" if l else f"{(names.get(p) or p)[:14]}"
            row.append(_btn(label, f"n:{p}"))
            if len(row) == 2:
                rows.append(row); row = []
        if row:
            rows.append(row)
        rows.append([_btn("🔄 刷新", "nl")] + NAV)
        n_on = sum(1 for p in nodes if live.get(p))
        return (f"🛰 <b>节点详情</b>\n<i>选一个节点查看 · {n_on} 个在线</i>\n\n"
                "🟢 后面的数字是当前在线 IP 数"), {"inline_keyboard": rows}
    if key.startswith("n:") or key.startswith("ns:"):
        p = key.split(":", 1)[1]
        if key.startswith("ns:"):
            con = db()
            tops = _top_sites(con, port=p, since=_today_start(), n=12)
            hist = _top_sites(con, port=p, since=0, n=10) if not tops else []
            con.close()
            lines = [f"🌐 <b>常去网站</b> · {_nlabel(p, names)}", ""]
            if tops:
                lines.append("<i>今天</i>")
                lines += [f"<code>{i:>2}</code>  {_nolink(n)}  <i>{c:,} 次</i>" for i, (n, c) in enumerate(tops, 1)]
            elif hist:
                lines.append("<i>今天还没有访问,下面是历史上最常去的</i>")
                lines += [f"<code>{i:>2}</code>  {_nolink(n)}  <i>{c:,} 次</i>" for i, (n, c) in enumerate(hist, 1)]
            else:
                lines.append("<i>还没有访问网站的记录</i>")
            return "\n".join(lines), _kb([_btn("« 返回节点", f"n:{p}"), _btn("🛰 节点列表", "nl")], NAV)
        return tg_handle_command(f"/node {p}"), _kb(
            [_btn("🔄 刷新", f"n:{p}"), _btn("🌐 常去网站", f"ns:{p}")],
            [_btn("« 节点列表", "nl")] + NAV)
    if key == "ip":
        return ("🔎 <b>查询 IP</b>\n\n直接把 IP 地址发给我,例如\n<code>203.0.113.10</code>\n\n"
                "<i>会返回它的归属地、连过哪些节点、常去哪些网站</i>"), _kb(NAV)
    if key == "set":
        cfg = tg_cfg()
        scope = cfg.get("nodes") or []
        lines = ["🔔 <b>通知设置</b>", "<i>点按钮开关,和网页里的设置同步</i>", "",
                 "状态  " + ("<b>✅ 已开启</b>" if cfg.get("enabled") else "<b>⏸ 已暂停</b>"),
                 "范围  " + (f"指定的 {len(scope)} 个节点" if scope else "全部节点"),
                 "免打扰  " + (f"{cfg.get('quiet_from')} – {cfg.get('quiet_to')}" if cfg.get("quiet") else "关闭")]
        rows = []
        for i in range(0, len(TG_EVENTS), 2):
            rows.append([_btn(("✅ " if cfg.get(k) else "▫️ ") + label, f"t:{k}") for k, label in TG_EVENTS[i:i + 2]])
        rows[-1].append(_btn(("🌙 免打扰 开" if cfg.get("quiet") else "🌙 免打扰 关"), "t:quiet"))
        rows.append([_btn("⏸ 暂停全部通知" if cfg.get("enabled") else "▶️ 恢复通知", "t:enabled")] + NAV)
        return "\n".join(lines), {"inline_keyboard": rows}
    if key == "help":
        return TG_HELP, _kb(NAV)
    return "这个按钮已经失效,请重新打开菜单。", _kb(NAV)

def tg_toggle(key):
    allowed = {k for k, _ in TG_EVENTS} | {"quiet", "enabled"}
    if key not in allowed:
        return
    s = load_settings()
    cur = dict(TG_DEFAULT)
    cur.update(s.get("tg") or {})
    cur[key] = not cur.get(key)
    s["tg"] = cur
    save_settings(s)

def tg_handle_command(text):
    cmd, _, arg = (text or "").strip().partition(" ")
    cmd = cmd.split("@")[0].lower()
    names = _node_names()
    if cmd in ("/start", "/help"):
        return TG_HELP
    if cmd == "/status":
        live = live_map()
        con = db()
        last = {r[0]: r[1] for r in con.execute("SELECT port, MAX(last_seen) FROM conn GROUP BY port")}
        con.close()
        nodes = _node_ports(names)
        on = sorted((p for p in nodes if live.get(p)), key=lambda p: -len(live[p]))
        off = sorted((p for p in nodes if not live.get(p)), key=lambda p: (last.get(p) is None, -(int(re.sub(r"\D", "", last.get(p) or "0") or 0)), names.get(p) or p))
        now = datetime.now(DISPLAY_TZ)
        out = ["📡 <b>节点状态</b>", f"<i>{now.strftime('%H:%M')} · {len(on)} 个在线 / 共 {len(nodes)} 个</i>", ""]
        for p in on:
            l = live[p]
            out.append(f"🟢 {_nlabel(p, names)}\n└ <b>{len(l)}</b> IP · <b>{sum(l.values())}</b> 连接")
        if not on:
            out.append("<i>当前没有节点有人在线</i>")
        if off:
            rows = []
            for p in off:
                ls = _short_ts(last.get(p))
                rows.append(f"{_esc(names.get(p) or '端口')} <code>{p}</code>  " + (f"<i>最近 {ls}</i>" if ls else "<i>无记录</i>"))
            out += ["", f"⚪ <b>离线 {len(off)} 个</b>", "<blockquote expandable>" + "\n".join(rows) + "</blockquote>"]
        return "\n".join(out)
    if cmd == "/node":
        p = _match_node(arg, names)
        if not p:
            return "没找到这个节点。\n<i>用法:/node 名称或端口,例如 /node tim</i>"
        live = live_map().get(p, {})
        since = _today_start()
        inb = {i["port"]: i for i in xui_inbounds()}.get(p, {})
        con = db()
        ips_today, reqs = con.execute("SELECT COUNT(DISTINCT ip), COUNT(*) FROM req WHERE port=? AND t>=?", (p, since)).fetchone()
        hist = con.execute("SELECT COUNT(*) FROM conn WHERE port=?", (p,)).fetchone()[0]
        last = con.execute("SELECT MAX(last_seen) FROM conn WHERE port=?", (p,)).fetchone()[0]
        proto = {"vmess": "VMess", "vless": "VLESS", "trojan": "Trojan", "shadowsocks": "Shadowsocks"}.get((inb.get("protocol") or "").lower(), inb.get("protocol") or "")
        traffic = (inb.get("up") or 0) + (inb.get("down") or 0)
        out = [f"🛰 {_nlabel(p, names)}" + (f"  <i>{_esc(proto)}</i>" if proto else ""),
               (f"🟢 在线 · <b>{len(live)}</b> IP · <b>{sum(live.values())}</b> 连接") if live else
               ("⚪ 离线" + (f" · 最近 {_short_ts(last)}" if last else " · 还没有连接记录")), "",
               f"<b>今日</b>   {ips_today} 个 IP · {reqs:,} 次请求",
               f"<b>累计</b>   {hist} 个 IP" + (f" · 流量 {_fmt_bytes(traffic)}" if traffic else "")]
        if live:
            rows = [f"<code>{ip}</code>  {n} 连接\n{_esc(_geo_short(con, ip))}"
                    for ip, n in sorted(live.items(), key=lambda x: -x[1])[:8]]
            out += ["", "<b>在线 IP</b>", "<blockquote>" + "\n\n".join(rows) + "</blockquote>"]
        tops = _top_sites(con, port=p, since=since, n=5)
        if tops:
            out += ([] if live else [""]) + ["<b>今日常去</b>", _sites_line(tops, counts=True)]
        con.close()
        return "\n".join(out)
    if cmd == "/ip":
        ip = norm_ip(arg.strip()) if arg.strip() else None
        if not ip:
            return "用法:/ip 地址,例如 /ip 203.0.113.10\n<i>也可以直接把 IP 发给我</i>"
        con = db()
        rows = con.execute("SELECT port, first_seen, last_seen, cnt FROM conn WHERE ip=? ORDER BY last_seen DESC", (ip,)).fetchall()
        out = [f"🔎 <b>{ip}</b>", f"<i>{_esc(_geo_short(con, ip))}</i>", ""]
        if not rows:
            out.append("<i>这个 IP 没有连接过任何节点</i>")
        else:
            out.append(f"<b>连过 {len(rows)} 个节点</b>")
            out.append("<blockquote>" + "\n\n".join(
                f"{_nlabel(p, names)}  {c:,} 次\n<i>首次 {_short_ts(f)} · 最近 {_short_ts(l)}</i>" for p, f, l, c in rows[:10]) + "</blockquote>")
        tops = _top_sites(con, ip=ip, since=0, n=6)
        if tops:
            out += ([] if rows else [""]) + ["<b>常去</b>", _sites_line(tops, counts=True)]
        con.close()
        return "\n".join(out)
    if cmd == "/today":
        return tg_report_text()[0]
    return "看不懂这条命令。\n\n" + TG_HELP

def tg_reply(cfg, text, markup=None, edit=None):
    """发送新消息,或(edit=(chat_id, message_id))原地更新按钮所在的那条消息"""
    token = cfg.get("token")
    if edit:
        r = tg_api(token, "editMessageText", {"chat_id": edit[0], "message_id": edit[1], "text": text[:4000],
                                              "parse_mode": "HTML", "disable_web_page_preview": True,
                                              "reply_markup": markup or {"inline_keyboard": []}})
        if r.get("ok") or "not modified" in str(r.get("description", "")):
            return r
    p = {"chat_id": cfg.get("chat_id"), "text": text[:4000], "parse_mode": "HTML", "disable_web_page_preview": True}
    if markup:
        p["reply_markup"] = markup
    with _tg_lock:
        return tg_api(token, "sendMessage", p)

def tg_route_text(text, names):
    """把用户发来的文字翻译成页面 key 或命令"""
    t = text.strip()
    if t in TG_REPLY_KEYS:
        return ("view", TG_REPLY_KEYS[t])
    if t.startswith("/"):
        cmd = t.split()[0].split("@")[0].lower()
        if cmd in ("/start", "/menu"):
            return ("start", None)
        if cmd == "/status":
            return ("view", "st")
        if cmd == "/today":
            return ("view", "td")
        if cmd == "/help":
            return ("view", "help")
        if cmd == "/node" and len(t.split()) == 1:
            return ("view", "nl")
        if cmd == "/node":
            p = _match_node(t.split(None, 1)[1], names)
            return ("view", f"n:{p}") if p else ("cmd", t)
        return ("cmd", t)
    if norm_ip(t):
        return ("cmd", f"/ip {t}")
    p = _match_node(t, names)
    if p:
        return ("view", f"n:{p}")
    return ("view", "m")

def tg_setup_bot(token):
    """设置机器人的命令菜单、简介和左下角菜单按钮(每次启动自动同步,不用手动保存)"""
    title = site_title()
    tg_api(token, "setMyCommands", {"commands": [
        {"command": "menu", "description": "🏠 主菜单"},
        {"command": "status", "description": "📡 节点状态"},
        {"command": "today", "description": "📊 今日概况"},
        {"command": "node", "description": "🛰 节点详情(可跟名称或端口)"},
        {"command": "ip", "description": "🔎 查询 IP(也可直接发 IP)"},
        {"command": "help", "description": "💡 使用帮助"},
    ]}, timeout=10)
    tg_api(token, "setMyShortDescription", {"short_description": f"{title}:节点在线通知与查询"[:120]}, timeout=10)
    tg_api(token, "setMyDescription", {"description": (
        f"{title}\n\n"
        "• 节点上线、新 IP 连接、疑似共享时推送通知\n"
        "• 每日日报:在线、请求和常去网站\n"
        "• 随时查询节点状态、IP 归属和访问记录\n\n"
        "点下方「开始」使用。")[:500]}, timeout=10)
    tg_api(token, "setChatMenuButton", {"menu_button": {"type": "commands"}}, timeout=10)

def tg_poll_worker():
    """长轮询接收机器人收到的消息和按钮点击:回复查询;记录发消息的人给「自动获取 Chat ID」用"""
    offset, cur_token = None, None
    while True:
        cfg = tg_cfg()
        token = cfg.get("token")
        if not token:
            time.sleep(10)
            continue
        if token != cur_token:
            cur_token, offset = token, None
            tg_api(token, "deleteWebhook", timeout=10)
            try:
                tg_setup_bot(token)
            except Exception as e:  # noqa
                print("telegram setup error:", e, file=sys.stderr)
            r = tg_api(token, "getUpdates", {"timeout": 0, "offset": -1}, timeout=15)
            if r.get("ok") and r["result"]:
                offset = r["result"][-1]["update_id"] + 1     # 跳过以前积压的旧消息
        r = tg_api(token, "getUpdates", {"timeout": 25, "offset": offset,
                                         "allowed_updates": ["message", "callback_query"]}, timeout=40)
        if not r.get("ok"):
            time.sleep(30 if "Unauthorized" in str(r.get("description")) else 5)
            continue
        for u in r.get("result", []):
            offset = u["update_id"] + 1
            try:
                _tg_handle_update(u)
            except Exception as e:  # noqa
                print("telegram update error:", e, file=sys.stderr)

def _tg_handle_update(u):
    cq = u.get("callback_query")
    msg = (cq or {}).get("message") or u.get("message") or {}
    chat = msg.get("chat") or {}
    cid = str(chat.get("id", ""))
    if not cid:
        return
    cfg = tg_cfg()
    token = cfg.get("token")
    if cq:
        if cid != str(cfg.get("chat_id")):
            tg_api(token, "answerCallbackQuery", {"callback_query_id": cq["id"], "text": "没有权限"})
            return
        data = cq.get("data") or "m"
        note = ""
        if data.startswith("t:"):
            tg_toggle(data[2:])
            note = "已更新"
            data = "set"
        tg_api(token, "answerCallbackQuery", {"callback_query_id": cq["id"], "text": note})
        if not cfg.get("commands"):
            tg_reply(cfg, "查询功能已在面板里关闭。", None, edit=(cid, msg.get("message_id")))
            return
        text, kb = tg_view(data)
        tg_reply(cfg, text, kb, edit=(cid, msg.get("message_id")))
        return
    text = msg.get("text") or ""
    who = chat.get("title") or " ".join(x for x in (chat.get("first_name"), chat.get("last_name")) if x) or chat.get("username") or cid
    _tg_seen_chats[cid] = (who, time.time())
    if cid != str(cfg.get("chat_id")):
        if text.startswith("/start"):
            tg_send(f"你好 {_esc(who)}!\n你的 Chat ID 是 <code>{cid}</code>\n回到面板的「Telegram 通知」里点「自动获取」即可绑定。",
                    cfg, force=True, chat_id=cid)
        return
    if not text:
        return
    if not cfg.get("commands"):
        tg_send("查询功能已在面板里关闭。", cfg, force=True)
        return
    kind, val = tg_route_text(text, _node_names())
    if kind == "start":
        tg_reply(cfg, f"👋 <b>欢迎使用 {_esc(site_title())}</b>\n<i>输入框下方的快捷键盘随时可以点</i>", _reply_kb())
        t, kb = tg_view("m")
        tg_reply(cfg, t, kb)
    elif kind == "view":
        t, kb = tg_view(val)
        tg_reply(cfg, t, kb)
    else:
        t = tg_handle_command(val)
        kb = _kb(NAV)
        if val.startswith("/ip "):
            kb = _kb([_btn("🛰 查看节点", "nl")], NAV)
        tg_reply(cfg, t, kb)

def tg_worker():
    """每 15 秒检查一次需要推送的事件"""
    state, first = {}, True
    last_rowid = None
    pending_new = []
    flags = {"log": False, "storage_day": "", "trim": None}
    while True:
        try:
            cfg = tg_cfg()
            active = bool(cfg.get("enabled") and cfg.get("token") and cfg.get("chat_id"))
            now = time.time()
            names = _node_names()
            watch = set(cfg.get("nodes") or []) or None
            live = live_map()
            msgs = []
            # --- 上线 / 下线 / 疑似共享
            for port in set(names) | set(live):
                ips = live.get(port, {})
                st = state.get(port)
                if st is None:
                    st = state[port] = {"online": bool(ips), "zero": None if ips else now, "share": 0}
                    continue
                watched = watch is None or port in watch
                if ips:
                    if not st["online"]:
                        st["online"] = True
                        if watched and cfg.get("ev_online") and not first:
                            con = db()
                            lst = "\n".join(f"<code>{ip}</code>  {_esc(_geo_short(con, ip))}" for ip in list(ips)[:5])
                            con.close()
                            msgs.append(f"🟢 <b>节点上线</b>  ·  {_nlabel(port, names)}\n<i>{len(ips)} 个 IP · {sum(ips.values())} 个连接</i>\n<blockquote>{lst}</blockquote>")
                    st["zero"] = None
                    n_share = max(2, int(cfg.get("share_n") or 3))
                    if len(ips) >= n_share and now - st["share"] > 3600:
                        st["share"] = now
                        if watched and cfg.get("ev_share") and not first:
                            con = db()
                            lst = "\n".join(f"<code>{ip}</code>  {_esc(_geo_short(con, ip))}" for ip in list(ips)[:10])
                            con.close()
                            msgs.append(f"⚠️ <b>疑似共享</b>  ·  {_nlabel(port, names)}\n<i>同时有 {len(ips)} 个 IP 在线</i>\n<blockquote expandable>{lst}</blockquote>")
                else:
                    if st["zero"] is None:
                        st["zero"] = now
                    mins = max(1, int(cfg.get("offline_min") or 10))
                    if st["online"] and now - st["zero"] >= mins * 60:
                        st["online"] = False
                        if watched and cfg.get("ev_offline") and not first:
                            msgs.append(f"⚪ <b>节点下线</b>  ·  {_nlabel(port, names)}\n<i>无人连接已超过 {mins} 分钟</i>")
            # --- 新 IP 首次连接(按 conn 表新增的行判断,短连接也不会漏)
            con = db()
            if last_rowid is None:
                last_rowid = con.execute("SELECT COALESCE(MAX(rowid), 0) FROM conn").fetchone()[0]
            for rid, port, ip in con.execute("SELECT rowid, port, ip FROM conn WHERE rowid > ? ORDER BY rowid", (last_rowid,)).fetchall():
                last_rowid = max(last_rowid, rid)
                if watch is None or port in watch:
                    pending_new.append((port, ip, now))
            keep = []
            for port, ip, t0 in pending_new:
                g = geo_info(con, ip)
                if g["loc"] == "查询中…" and now - t0 < 60:
                    keep.append((port, ip, t0))           # 等归属地查到再发,最多等 1 分钟
                    continue
                if cfg.get("ev_new_ip"):
                    msgs.append(f"🆕 <b>新 IP 连接</b>  ·  {_nlabel(port, names)}\n<blockquote><code>{ip}</code>\n{_esc(_geo_short(con, ip))}</blockquote>")
            pending_new = keep
            # --- 日志中断:有人在线,但访问日志 30 分钟没有新内容
            try:
                stale = time.time() - os.stat(LOG_PATH).st_mtime > 1800
            except OSError:
                stale = True
            if stale and live and not flags["log"]:
                flags["log"] = True
                if cfg.get("ev_log") and not first:
                    msgs.append("🚨 <b>访问日志中断</b>\n<i>节点上有人在线,但日志 30 分钟没有新内容</i>\n\n"
                                "可能是 x-ui 升级或改了设置,把访问日志关掉了,面板会因此收不到新数据。\n"
                                "<blockquote>重新运行一次安装脚本即可自动恢复</blockquote>")
            elif not stale and flags["log"]:
                flags["log"] = False
                if cfg.get("ev_log"):
                    msgs.append("✅ <b>访问日志已恢复</b>\n<i>面板重新开始记录</i>")
            # --- 存储告警
            if cfg.get("ev_storage"):
                dbb, logs = storage_usage()
                pct = (dbb + logs) * 100 // max(1, STORAGE_MAX_MB * 1024 * 1024)
                today = datetime.now(DISPLAY_TZ).strftime("%Y-%m-%d")
                if pct >= 85 and flags["storage_day"] != today:
                    flags["storage_day"] = today
                    msgs.append(f"💾 <b>存储空间告警</b>\n<i>面板占用已到上限的 {pct}%</i>\n\n"
                                f"{_fmt_bytes(dbb + logs)} / {_fmt_bytes(STORAGE_MAX_MB * 1048576)},接下来会自动清理最旧的数据。")
                row = con.execute("SELECT v FROM meta WHERE k='last_trim'").fetchone()
                trim = row[0] if row else None
                if flags["trim"] is None:
                    flags["trim"] = trim or ""
                elif trim and trim != flags["trim"]:
                    flags["trim"] = trim
                    msgs.append("🧹 <b>已自动清理旧数据</b>\n<i>" + _esc(trim.partition("|")[2].replace(";", "、")) + "</i>")
            # --- 每日日报
            if cfg.get("ev_daily"):
                nowl = datetime.now(DISPLAY_TZ)
                today = nowl.strftime("%Y-%m-%d")
                row = con.execute("SELECT v FROM meta WHERE k='tg_daily'").fetchone()
                due = nowl.hour * 60 + nowl.minute >= _hm(cfg.get("daily_time"), 9 * 60)
                if due and (not row or row[0] != today):
                    con.execute("REPLACE INTO meta VALUES('tg_daily', ?)", (today,))
                    con.commit()
                    if active and not tg_in_quiet(cfg):
                        text, traffic = tg_report_text(watch, "每日日报")
                        if tg_send(text, cfg).get("ok"):
                            con.execute("REPLACE INTO meta VALUES('tg_traffic_snap', ?)", (json.dumps(traffic),))
                            con.commit()
            con.close()
            if active:
                for m in msgs[:20]:
                    tg_send(m, cfg)
            first = False
        except Exception as e:  # noqa
            print("telegram worker error:", e, file=sys.stderr)
        time.sleep(15)

def _mask_token(t):
    return (t[:6] + "…" + t[-4:]) if t and len(t) > 12 else ("已填写" if t else "")

@app.get("/api/tg")
def api_tg_get():
    cfg = tg_cfg()
    token = cfg.pop("token", "")
    cfg["token_set"] = bool(token)
    cfg["token_hint"] = _mask_token(token)
    cfg["bot"] = tg_bot_name(token) if token else ""
    return jsonify(cfg)

def _clean_tg(d, old):
    out = dict(TG_DEFAULT)
    out.update(old)
    for k in ("enabled", "commands", "ev_online", "ev_offline", "ev_new_ip", "ev_share", "ev_daily", "ev_log", "ev_storage", "quiet"):
        if k in d:
            out[k] = bool(d[k])
    for k, lo, hi in (("offline_min", 1, 1440), ("share_n", 2, 50)):
        if k in d:
            try:
                out[k] = min(hi, max(lo, int(d[k])))
            except (TypeError, ValueError):
                pass
    for k in ("daily_time", "quiet_from", "quiet_to"):
        if k in d and re.fullmatch(r"\d{1,2}:\d{2}", str(d[k])):
            out[k] = str(d[k])
    if "chat_id" in d:
        out["chat_id"] = re.sub(r"[^0-9-]", "", str(d["chat_id"]))[:20]
    if "nodes" in d and isinstance(d["nodes"], list):
        out["nodes"] = [str(x) for x in d["nodes"]][:200]
    tok = str(d.get("token", "")).strip()
    if tok:
        out["token"] = tok
    if d.get("clear_token"):
        out["token"] = ""
    return out

@app.post("/api/tg")
def api_tg_save():
    d = request.get_json(silent=True) or {}
    s = load_settings()
    old = s.get("tg") or {}
    new = _clean_tg(d, old)
    if new["token"] and new["token"] != old.get("token"):
        if not tg_bot_name(new["token"]):
            return jsonify({"error": "Bot Token 无效,Telegram 不认识这个机器人"}), 400
    if new["enabled"] and not (new["token"] and new["chat_id"]):
        return jsonify({"error": "要启用通知,需要先填好 Bot Token 和 Chat ID"}), 400
    s["tg"] = new
    save_settings(s)
    if new["token"]:
        tg_setup_bot(new["token"])
    return jsonify({"ok": True, "bot": tg_bot_name(new["token"])})

@app.post("/api/tg/test")
def api_tg_test():
    d = request.get_json(silent=True) or {}
    cfg = _clean_tg(d, tg_cfg())
    if not cfg["token"] or not cfg["chat_id"]:
        return jsonify({"error": "先填好 Bot Token 和 Chat ID"}), 400
    r = tg_send(f"✅ <b>通知已接通</b>\n<i>{_esc(site_title())}</i>\n\n发送 /menu 打开按钮菜单。", cfg, force=True)
    if not r.get("ok"):
        desc = str(r.get("description", ""))
        if "chat not found" in desc:
            desc = "找不到这个 Chat ID。请先在 Telegram 里给机器人发一条 /start"
        elif "Unauthorized" in desc:
            desc = "Bot Token 无效"
        return jsonify({"error": "发送失败:" + desc}), 400
    return jsonify({"ok": True})

@app.post("/api/tg/detect")
def api_tg_detect():
    d = request.get_json(silent=True) or {}
    token = str(d.get("token", "")).strip() or tg_cfg().get("token")
    if not token:
        return jsonify({"error": "先填写 Bot Token"}), 400
    bot = tg_bot_name(token)
    if not bot:
        return jsonify({"error": "Bot Token 无效,Telegram 不认识这个机器人"}), 400
    if token != tg_cfg().get("token"):
        # 新 token 还没保存,后台轮询线程还没在用它,直接取一次消息
        tg_api(token, "deleteWebhook", timeout=10)
        r = tg_api(token, "getUpdates", {"timeout": 0}, timeout=15)
        for u in (r.get("result") or []):
            chat = (u.get("message") or {}).get("chat") or {}
            if chat.get("id"):
                who = chat.get("title") or " ".join(x for x in (chat.get("first_name"), chat.get("last_name")) if x) or chat.get("username") or ""
                _tg_seen_chats[str(chat["id"])] = (who, time.time())
    if not _tg_seen_chats:
        return jsonify({"error": f"还没收到消息。请在 Telegram 里打开 {bot},发送 /start,再点一次「自动获取」", "bot": bot}), 404
    cid, (who, _t) = max(_tg_seen_chats.items(), key=lambda kv: kv[1][1])
    return jsonify({"ok": True, "chat_id": cid, "name": who, "bot": bot})

def cert_watcher():
    """证书续期后(文件被替换)自动退出,由 systemd 重启并加载新证书"""
    def sig():
        return tuple(os.stat(p).st_mtime_ns for p in (SSL_CERT, SSL_KEY))
    base = sig()
    while True:
        time.sleep(6 * 3600)
        try:
            if sig() != base:
                print("证书已更新,重启以加载新证书", flush=True)
                os._exit(0)
        except OSError:
            pass

def main():
    if not ADMIN_PASS and not os.path.exists(AUTH_FILE):
        sys.exit("请先设置环境变量 ADMIN_PASS(网页登录密码)")
    if (SSL_CERT or SSL_KEY) and not TLS_ON:
        print("警告:找不到证书文件,改用 HTTP 启动", file=sys.stderr, flush=True)
    init_db()
    app.secret_key = secret_key()
    for fn in (ingest_worker, sampler_worker, geo_worker, ipname_worker, tg_worker, tg_poll_worker):
        threading.Thread(target=fn, daemon=True).start()
    from cheroot.wsgi import Server
    srv = Server((HOST, PORT), app, numthreads=8, request_queue_size=64)
    if TLS_ON:
        from cheroot.ssl.builtin import BuiltinSSLAdapter
        srv.ssl_adapter = BuiltinSSLAdapter(SSL_CERT, SSL_KEY)
        threading.Thread(target=cert_watcher, daemon=True).start()
    print(f"listening on {'https' if TLS_ON else 'http'}://{HOST}:{PORT}", flush=True)
    try:
        srv.start()
    except KeyboardInterrupt:
        srv.stop()

if __name__ == "__main__":
    main()
PYEOF
chmod 644 "$APP_DIR/app.py" "$APP_DIR/requirements.txt"

echo "==> [3/6] 创建虚拟环境并安装依赖(首次约半分钟)"
[ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

echo "==> [4/6] 生成配置(密码 / 域名证书 / 端口)"

# ---- 账号密码 ----
ADMIN_USER="${ADMIN_USER:-${OLD_USER:-tim}}"
PW_FROM_WEB=0
if [ -n "${ADMIN_PASS:-}" ]; then
  rm -f "$APP_DIR/data/auth.json"          # 明确指定了新密码:覆盖掉网页里改过的
elif [ -f "$APP_DIR/data/auth.json" ]; then
  PW_FROM_WEB=1; ADMIN_PASS="$OLD_PASS"    # 密码已在网页里修改过,沿用
else
  ADMIN_PASS="$OLD_PASS"
fi
if [ -z "${ADMIN_PASS:-}" ]; then
  ADMIN_PASS="tim"                         # 新安装的默认密码,可在网页里修改
fi

# ---- 监听地址 ----
case "${PUBLIC:-}" in
  1) LISTEN_HOST=0.0.0.0 ;;
  0) LISTEN_HOST=127.0.0.1 ;;
  *) LISTEN_HOST="${OLD_HOST:-127.0.0.1}" ;;
esac

# ---- 域名证书 ----
DOMAIN="${DOMAIN-$OLD_DOMAIN}"             # 没传 DOMAIN 就沿用旧的;DOMAIN=off 关闭
[ "$DOMAIN" = "off" ] && DOMAIN=""
SSL_CERT=""; SSL_KEY=""; TLS=0; CERT_MSG=""

# >>> certfuncs
cert_ok() {  # $1=证书 $2=私钥:可读、域名匹配、公钥和私钥配对
  [ -r "$1" ] && [ -r "$2" ] || return 1
  openssl x509 -in "$1" -noout -checkhost "$DOMAIN" 2>/dev/null | grep -q "does match" || return 1
  local a b
  a="$(openssl x509 -in "$1" -noout -pubkey 2>/dev/null | sha256sum | cut -d' ' -f1)"
  b="$(openssl pkey -in "$2" -pubout 2>/dev/null | sha256sum | cut -d' ' -f1)"
  [ -n "$a" ] && [ "$a" = "$b" ]
}

find_cert() {
  local pair c k f d h
  local -a pairs=()
  [ -n "${CERT_FILE:-}" ] && [ -n "${KEY_FILE:-}" ] && pairs+=("$CERT_FILE|$KEY_FILE")
  [ -n "$OLD_SSL_CERT" ] && pairs+=("$OLD_SSL_CERT|$OLD_SSL_KEY")
  if [ -f "$XUI_DB" ]; then                # x-ui 面板里配置的证书
    pair="$(python3 - "$XUI_DB" <<'PYX' 2>/dev/null || true
import sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
d = dict(c.execute("select key, value from settings where key in ('webCertFile','webKeyFile')").fetchall())
print((d.get("webCertFile") or "") + "|" + (d.get("webKeyFile") or ""))
PYX
)"
    [ -n "$pair" ] && [ "$pair" != "|" ] && pairs+=("$pair")
  fi
  for h in /root /home/*; do               # acme.sh 的默认目录
    pairs+=("$h/.acme.sh/${DOMAIN}_ecc/fullchain.cer|$h/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.key")
    pairs+=("$h/.acme.sh/${DOMAIN}/fullchain.cer|$h/.acme.sh/${DOMAIN}/${DOMAIN}.key")
  done
  pairs+=("/etc/letsencrypt/live/${DOMAIN}/fullchain.pem|/etc/letsencrypt/live/${DOMAIN}/privkey.pem")
  for pair in "${pairs[@]}"; do
    c="${pair%%|*}"; k="${pair#*|}"
    if cert_ok "$c" "$k"; then SSL_CERT="$c"; SSL_KEY="$k"; return 0; fi
  done
  # 兜底:扫描常见目录里的证书文件,在同一目录里找配对的私钥(优先 fullchain)
  while IFS= read -r f; do
    d="$(dirname "$f")"
    for k in "$d"/*.key "$d"/privkey.pem "$d"/*key*.pem; do
      [ -f "$k" ] || continue
      if cert_ok "$f" "$k"; then SSL_CERT="$f"; SSL_KEY="$k"; return 0; fi
    done
  done < <(find /root /home /etc/ssl /etc/x-ui /usr/local/x-ui /opt /etc/letsencrypt /etc/nginx /etc/caddy \
             -maxdepth 5 -type f \( -name '*.crt' -o -name '*.cer' -o -name '*.pem' \) \
             -not -path '*/venv/*' -not -path '*/site-packages/*' 2>/dev/null \
           | sort | awk '/fullchain/{print; next} {o[n++]=$0} END{for(i=0;i<n;i++) print o[i]}' | head -n 300)
  return 1
}
# <<< certfuncs

if [ -n "$DOMAIN" ]; then
  if find_cert; then
    TLS=1; LISTEN_HOST=0.0.0.0
    CERT_MSG="已找到 $DOMAIN 的证书: $SSL_CERT"
  else
    CERT_MSG="没有找到 $DOMAIN 的有效证书(或域名/私钥对不上),先用 HTTP 运行。找到证书路径后加上 CERT_FILE=... KEY_FILE=... 重新运行本脚本即可。"
  fi
  echo "    $CERT_MSG"
fi
# 之前是 HTTPS 对外开放、这次却没有可用证书(或关闭了 HTTPS):不能让明文 HTTP 意外暴露在公网
if [ "$TLS" = 0 ] && [ -n "$OLD_SSL_CERT" ] && [ -z "${PUBLIC:-}" ]; then
  LISTEN_HOST=127.0.0.1
  echo "    HTTPS 未启用,已改为只监听本机(如确实要 HTTP 公网访问,请加 PUBLIC=1)"
fi

# ---- 端口 ----
USED="$(ss -tln 2>/dev/null | awk 'NR>1{print $4}' || true)"
port_free() { ! grep -qE "[:.]$1\$" <<<"$USED"; }
LISTEN_PORT=""
if [ -n "${PORT:-}" ]; then
  LISTEN_PORT="$PORT"
elif [ "$TLS" = 1 ]; then
  if [ -n "$OLD_PORT" ] && [ -n "$OLD_SSL_CERT" ]; then
    LISTEN_PORT="$OLD_PORT"                # 之前就是 HTTPS,端口不变
  else                                     # 优先 443;被占用就换 Cloudflare 也支持代理的 HTTPS 端口
    for p in 443 8443 2053 2083 2087 2096 18443 28443; do
      if port_free "$p"; then LISTEN_PORT="$p"; break; fi
    done
    LISTEN_PORT="${LISTEN_PORT:-18443}"
  fi
elif [ -n "$OLD_PORT" ] && [ -z "$OLD_SSL_CERT" ]; then
  LISTEN_PORT="$OLD_PORT"
else
  LISTEN_PORT=18088
  while ! port_free "$LISTEN_PORT"; do LISTEN_PORT=$((LISTEN_PORT+1)); done
fi

umask 077
cat > "$ENV_FILE" <<ENVEOF
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
HOST=$LISTEN_HOST
PORT=$LISTEN_PORT
DOMAIN=$DOMAIN
SSL_CERT=$SSL_CERT
SSL_KEY=$SSL_KEY
XRAY_ACCESS_LOG=$LOG
XUI_DB=$XUI_DB
DB_PATH=$APP_DIR/data/ips.db
DISPLAY_TZ_HOURS=8
DETAIL_DAYS=30
SITE_DAYS=90
SITE_IDLE_GAP=300
STORAGE_MAX_GB=$STORAGE_MAX_GB
MIN_FREE_MB=2048
PANEL_VERSION=$PANEL_VERSION
IP_PROBE=${IP_PROBE:-${OLD_IPPROBE:-1}}
ENVEOF
chmod 600 "$ENV_FILE"
umask 022

# 以 root 运行(要读 root 才能读的 Xray 日志、x-ui 数据库和证书),并用 systemd 做沙箱限制:
# 整个系统只读,仅 data 目录可写
cat > "/etc/systemd/system/$SVC.service" <<SVCEOF
[Unit]
Description=Xray IP Viewer
After=network.target
StartLimitIntervalSec=0

[Service]
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/venv/bin/python app.py
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadWritePaths=$APP_DIR/data $(dirname "$LOG")

[Install]
WantedBy=multi-user.target
SVCEOF

cat > /etc/logrotate.d/xray <<LREOF
$LOG {
    daily
    maxsize 200M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LREOF

echo "==> [5/6] 为 x-ui 开启 Xray 访问日志"
XUI_RESULT="SKIP"
if [ -f "$XUI_DB" ]; then
  XUI_RESULT="$(python3 - "$XUI_DB" "$LOG" <<'PYEOF2' || echo ERROR
import sqlite3, json, sys, shutil, time
db, log = sys.argv[1], sys.argv[2]
try:
    con = sqlite3.connect(db, timeout=30)
    row = con.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
    if not row:
        print("NOTFOUND"); sys.exit(0)
    cfg = json.loads(row[0])
    lg = cfg.setdefault("log", {})
    if lg.get("access") == log:
        print("ALREADY"); sys.exit(0)
    shutil.copy(db, "%s.bak.%d" % (db, int(time.time())))
    lg["access"] = log
    lg.setdefault("loglevel", "warning")
    con.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
                (json.dumps(cfg, indent=2, ensure_ascii=False),))
    con.commit()
    print("PATCHED")
except Exception as e:
    print("ERROR")
PYEOF2
)"
fi
case "$XUI_RESULT" in
  PATCHED)
    echo "    已修改 x-ui 配置模板(原数据库已备份为 $XUI_DB.bak.*),重启 x-ui..."
    systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || echo "    请手动重启 x-ui"
    ;;
  ALREADY) echo "    x-ui 已开启访问日志,无需修改" ;;
  SKIP)    echo "    没找到 $XUI_DB,端口总览将为空;请确认 x-ui 数据库位置" ;;
  *)       echo "    未能自动修改(${XUI_RESULT}),请手动开启(见下方提示)" ;;
esac

echo "==> [6/6] 启动服务"
systemctl daemon-reload
systemctl enable "$SVC" >/dev/null 2>&1
systemctl reset-failed "$SVC" 2>/dev/null || true
systemctl restart "$SVC"

check_up() {  # $1=端口 $2=http|https
  python3 -c 'import sys, ssl, urllib.request as u
ctx = ssl._create_unverified_context() if sys.argv[2] == "https" else None
try:
    r = u.urlopen("%s://127.0.0.1:%s/healthz" % (sys.argv[2], sys.argv[1]), timeout=2, context=ctx)
    sys.exit(0 if r.read().strip() == b"ok" else 1)
except Exception:
    sys.exit(1)' "$1" "$2" 2>/dev/null
}
SCHEME=http; [ "$TLS" = 1 ] && SCHEME=https
STATE="启动失败,请查看: journalctl -u $SVC -n 50 --no-pager"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if check_up "$LISTEN_PORT" "$SCHEME"; then STATE="运行中"; break; fi
  sleep 1
done

# 对外开放时,如果启用了 ufw,顺手放行端口
if [ "$LISTEN_HOST" = "0.0.0.0" ] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$LISTEN_PORT/tcp" >/dev/null 2>&1 && echo "    已在 ufw 放行 $LISTEN_PORT/tcp"
fi

SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SSH_PORT="$(ss -tlnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]; exit}' || true)"
SSH_PORT="${SSH_PORT:-22}"
SHOWPORT=":$LISTEN_PORT"
{ [ "$SCHEME" = https ] && [ "$LISTEN_PORT" = 443 ]; } && SHOWPORT=""

echo
echo "================ 完成 ================"
echo "服务状态: $STATE"
SHOW_USER="$ADMIN_USER"
if [ "$PW_FROM_WEB" = 1 ]; then
  SHOW_USER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["user"])' "$APP_DIR/data/auth.json" 2>/dev/null || echo "$ADMIN_USER")"
fi
echo "登录账号: $SHOW_USER"
if [ "$PW_FROM_WEB" = 1 ]; then
  echo "登录密码: 沿用你在网页里修改后的密码(忘了的话: sudo ADMIN_PASS=新密码 bash xray-traffic-panel.sh 重置)"
else
  echo "登录密码: $ADMIN_PASS   (保存在 $ENV_FILE;登录后可在网页里修改)"
fi
echo
if [ "$TLS" = 1 ]; then
  echo "访问地址: https://$DOMAIN$SHOWPORT"
  DOMAIN_IP="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ -n "$DOMAIN_IP" ] && ! hostname -I 2>/dev/null | tr ' ' '\n' | grep -qx "$DOMAIN_IP"; then
    echo "  * 注意: $DOMAIN 解析到 $DOMAIN_IP,不在本机网卡地址里(本机: ${SERVER_IP:-未知})。"
    echo "    如果是 Cloudflare 的橙色云代理:SSL 模式要选 Full (strict),端口要是 CF 支持的(443/8443/2053/2083/2087/2096);"
    echo "    不想用代理就把 DNS 记录改成「仅 DNS」(灰色云)。"
  elif [ -z "$DOMAIN_IP" ]; then
    echo "  * 注意: 当前解析不到 $DOMAIN,请确认 DNS 已指向这台服务器。"
  fi
  echo "  * 如果打不开,请到 VPS 商家后台的安全组/防火墙里放行 TCP $LISTEN_PORT"
  echo "  * 证书续期后程序会在 6 小时内自动重启并加载新证书"
elif [ "$LISTEN_HOST" = "0.0.0.0" ]; then
  echo "访问地址: http://${SERVER_IP:-服务器IP}:$LISTEN_PORT"
  echo "  * 如果打不开,请到 VPS 商家后台的安全组/防火墙里放行 TCP $LISTEN_PORT"
  echo "  * 这是 HTTP,密码会明文传输;建议重新运行本脚本并输入域名,改用 HTTPS"
else
  echo "访问方式(当前只监听本机,用 SSH 隧道):"
  echo "  在你自己电脑上执行:  ssh -p $SSH_PORT -L $LISTEN_PORT:127.0.0.1:$LISTEN_PORT root@${SERVER_IP:-服务器IP}"
  echo "  然后浏览器打开:      http://127.0.0.1:$LISTEN_PORT"
  echo "  想用域名访问:        重新运行 sudo bash xray-traffic-panel.sh,按提示输入域名"
fi
echo
echo "注意:"
echo "  * 只能统计开启日志之后的连接;有人连过节点后,对应端口才会出现 IP。"
echo "  * 如果上面提示没能自动开启日志,请在 x-ui 面板 → Xray 相关设置 里,"
echo "    给配置模板加上: \"log\": { \"access\": \"$LOG\", \"loglevel\": \"warning\" },"
echo "    保存并重启 x-ui。"
echo "  * 面板最多占用 ${STORAGE_MAX_GB} GB(数据库 + 访问日志),超过会自动清理最旧的数据"
echo "  * 升级: 重新运行一次本脚本(或 README 里的一键命令),数据和设置都会保留"
echo "  * 卸载: bash xray-traffic-panel.sh uninstall(保留数据)  /  purge(连数据一起删除)"
echo "======================================"