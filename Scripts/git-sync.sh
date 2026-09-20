#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  print -u2 "当前处于 detached HEAD，请先切换到需要更新的分支。"
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "工作区尚有未保存改动。请先发布或提交检查点，再同步远程。"
  exit 1
fi

git fetch --prune origin
if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  git pull --ff-only origin "$branch"
else
  print "远程尚无 $branch 分支；本地无需合并。首次发布时会自动创建。"
fi
git status --short --branch
