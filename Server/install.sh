#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Linux && "$EUID" -eq 0 ]] || { echo '请在目标 Linux 服务器以 sudo 运行。' >&2; exit 1; }
command -v java >/dev/null || { echo '请先安装 Java 11 或更新版本的运行环境。' >&2; exit 1; }
command -v openssl >/dev/null
getent group study-planner-sync >/dev/null || groupadd --system study-planner-sync
id study-planner-sync >/dev/null 2>&1 || useradd --system --gid study-planner-sync --home-dir /var/lib/study-planner-sync --shell /usr/sbin/nologin study-planner-sync
install -d -m 0755 /opt/study-planner-sync/lib
install -d -m 0750 -o root -g study-planner-sync /etc/study-planner-sync
install -d -m 0700 -o study-planner-sync -g study-planner-sync /var/lib/study-planner-sync
# Explicitly stop an existing instance during upgrade; its data and configuration stay in place.
if systemctl cat study-planner-sync.service >/dev/null 2>&1; then systemctl stop study-planner-sync.service; fi
install -m 0644 lib/study-planner-server.jar lib/json.jar /opt/study-planner-sync/lib/
install -m 0755 start.sh /opt/study-planner-sync/start.sh
install -m 0755 backup.sh /opt/study-planner-sync/backup.sh
install -m 0644 README.md JSON-java-LICENSE.txt /opt/study-planner-sync/
if [[ ! -e /etc/study-planner-sync/server.env ]]; then
  install -m 0640 -o root -g study-planner-sync server.env.example /etc/study-planner-sync/server.env
fi
if [[ ! -e /etc/study-planner-sync/token ]]; then
  umask 0077
  openssl rand -hex 32 > /etc/study-planner-sync/token
  chown root:study-planner-sync /etc/study-planner-sync/token
  chmod 0640 /etc/study-planner-sync/token
fi
chown root:study-planner-sync /etc/study-planner-sync/server.env /etc/study-planner-sync/token
chmod 0640 /etc/study-planner-sync/server.env /etc/study-planner-sync/token
install -m 0644 study-planner-sync.service /etc/systemd/system/study-planner-sync.service
systemctl daemon-reload
echo '安装完成，尚未启动服务。请检查 /etc/study-planner-sync/server.env，配置 HTTPS 反向代理后手动 enable --now study-planner-sync。访问码仅保存在 /etc/study-planner-sync/token，请在服务器本地安全读取，勿粘贴到聊天或日志。'
