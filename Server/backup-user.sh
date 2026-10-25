#!/usr/bin/env bash
set -euo pipefail
[[ "$EUID" -ne 0 && $# -eq 1 && "$1" == /* ]] || { echo '用法：./backup-user.sh /自己projects内的备份目录' >&2; exit 1; }
project="$(cd "$(dirname "$0")" && pwd -P)"
destination="$(readlink -m -- "$1")"
projects="$(readlink -m -- "$HOME/projects")"
case "$destination" in "$project/data"|"$project/data/"*) echo '备份目录必须位于服务数据目录之外。' >&2; exit 1;; esac
case "$destination" in "$projects/"*) ;; *) echo '备份目录必须位于自己的 ~/projects/ 内。' >&2; exit 1;; esac
umask 0077
mkdir -p "$destination"
chmod 0700 "$destination"
was_running=false
if systemctl --user is-active --quiet study-planner-sync.service; then
  was_running=true
  systemctl --user stop study-planner-sync.service
fi
trap 'if $was_running; then systemctl --user start study-planner-sync.service; fi' EXIT
archive="$(mktemp "$destination/study-planner-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX.tar.gz")"
if ! tar -czf "$archive" -C "$project" data; then
  rm -f -- "$archive"
  exit 1
fi
echo "数据备份完成：$archive；原本运行中的用户服务将恢复。"
