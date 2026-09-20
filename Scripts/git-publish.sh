#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
message="${*:-}"
if [[ -z "$message" ]]; then
  print -u2 "用法：./Scripts/git-publish.sh \"这次更新的说明\""
  exit 1
fi
branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  print -u2 "当前处于 detached HEAD，请先切换或创建分支。"
  exit 1
fi

git fetch --prune origin
if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  counts="$(git rev-list --left-right --count "$branch...origin/$branch")"
  behind="${counts##*$'\t'}"
  if (( behind > 0 )); then
    print -u2 "远程 $branch 比本地新 $behind 个提交。请先运行 ./Scripts/git-sync.sh。"
    exit 1
  fi
fi

git add -A
if git diff --cached --quiet; then
  print "没有需要发布的改动。"
  exit 0
fi

git commit -m "$message"
git push -u origin "$branch"
print "已发布 $branch：$(git rev-parse --short HEAD)"
