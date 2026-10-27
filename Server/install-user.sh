#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
[[ "$(uname -s)" == Linux && "$EUID" -ne 0 && $# -le 1 ]] || { echo '请以普通 Linux 用户运行：./install-user.sh [/绝对路径/到/java]' >&2; exit 1; }
java_bin="${1:-$(command -v java || true)}"
[[ -n "$java_bin" && -x "$java_bin" ]] || { echo '请先在自己的目录解压 Java 11+ 运行环境，并传入 java 的绝对路径。' >&2; exit 1; }
java_bin="$(readlink -f -- "$java_bin")"
major="$("$java_bin" -version 2>&1 | sed -nE 's/.*version "([0-9]+).*/\1/p' | head -n 1)"
[[ "$major" =~ ^[0-9]+$ && "$major" -ge 11 ]] || { echo '需要 Java 11 或更新版本。' >&2; exit 1; }
project="$HOME/projects/study-planner-sync"
# These paths are written to a quoted systemd EnvironmentFile; reject control/escape characters.
for path in "$project" "$java_bin"; do
  [[ "$path" == /* && "$path" != *[\"\\%]* && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || { echo '安装路径不能含引号、反斜杠、百分号或换行。' >&2; exit 1; }
done
command -v openssl >/dev/null
systemctl --user show-environment >/dev/null
for file in lib/study-planner-server.jar lib/json.jar start-user.sh backup-user.sh README.md JSON-java-LICENSE.txt VERSION; do
  [[ -f "$file" ]] || { echo "部署包缺少文件：$file" >&2; exit 1; }
done
umask 0077
mkdir -p "$project/lib" "$project/config" "$project/data" "$HOME/.config/systemd/user"
chmod 0700 "$project" "$project/config" "$project/data"
if systemctl --user is-active --quiet study-planner-sync.service; then
  systemctl --user stop study-planner-sync.service
fi
install -m 0644 lib/study-planner-server.jar lib/json.jar "$project/lib/"
install -m 0755 start-user.sh backup-user.sh "$project/"
install -m 0644 README.md JSON-java-LICENSE.txt VERSION "$project/"
if [[ ! -e "$project/config/server.env" ]]; then
  cat > "$project/config/server.env" <<EOF
STUDY_SYNC_BIND=127.0.0.1
STUDY_SYNC_PORT=18090
STUDY_SYNC_DATA="$project/data"
STUDY_SYNC_TOKEN_FILE="$project/config/token"
STUDY_SYNC_JAVA="$java_bin"
EOF
fi
if [[ ! -e "$project/config/token" ]]; then
  openssl rand -hex 32 > "$project/config/token"
fi
chmod 0600 "$project/config/server.env" "$project/config/token"
cat > "$HOME/.config/systemd/user/study-planner-sync.service" <<'EOF'
[Unit]
Description=Study Planner private cloud synchronization (user)
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
WorkingDirectory=%h/projects/study-planner-sync
EnvironmentFile=%h/projects/study-planner-sync/config/server.env
ExecStart=%h/projects/study-planner-sync/start-user.sh
Restart=on-failure
RestartSec=30
UMask=0077
NoNewPrivileges=true
MemoryAccounting=yes
MemoryHigh=160M
MemoryMax=192M
MemorySwapMax=0
TasksMax=32
CPUQuota=50%

[Install]
WantedBy=default.target
EOF
chmod 0600 "$HOME/.config/systemd/user/study-planner-sync.service"
systemctl --user daemon-reload
echo '用户级安装完成，尚未启动。仅监听本机 127.0.0.1:18090，公网使用前仍需配置可信 HTTPS。'
echo '检查后运行：systemctl --user enable --now study-planner-sync'
echo '访问码仅保存在 ~/projects/study-planner-sync/config/token，请勿输出到聊天、Git 或日志。'
