#!/usr/bin/env bash
set -euo pipefail
[[ "$EUID" -eq 0 && $# -eq 1 ]] || { echo '用法：sudo ./backup.sh /绝对路径/备份目录' >&2; exit 1; }
destination="$1"
[[ "$destination" == /* ]] || { echo '备份目录必须是绝对路径' >&2; exit 1; }
destination="$(readlink -m -- "$destination")"
case "$destination" in /var/lib/study-planner-sync|/var/lib/study-planner-sync/*) echo '备份目录必须位于服务数据目录之外' >&2; exit 1;; esac
install -d -m 0700 "$destination"
was_running=false
if systemctl is-active --quiet study-planner-sync; then was_running=true; systemctl stop study-planner-sync; fi
trap 'if $was_running; then systemctl start study-planner-sync; fi' EXIT
umask 0077
# Immutable archives plus the persistent identity are enough to reconstruct the latest state.
# Tokens are deliberately excluded; store credentials using your own secure backup method.
tar -czf "$destination/study-planner-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" -C /var/lib study-planner-sync
echo '数据备份完成；原本运行中的服务将恢复。'
