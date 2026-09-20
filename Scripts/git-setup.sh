#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
expected="${1:-https://github.com/DenseFLoe/study-planner.git}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  print -u2 "当前目录不是 Git 仓库。"
  exit 1
fi

if git remote get-url origin >/dev/null 2>&1; then
  actual="$(git remote get-url origin)"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "origin 当前为：$actual"
    print -u2 "为避免连到错误仓库，未自动改为：$expected"
    print -u2 "请确认后手动执行：git remote set-url origin '$expected'"
    exit 1
  fi
else
  git remote add origin "$expected"
fi

git config --local core.hooksPath .githooks
git config --local fetch.prune true
git config --local pull.rebase true
git config --local rebase.autoStash true
git config --local push.autoSetupRemote true

print "已连接：$(git remote get-url origin)"
print "已启用：远程分支清理、rebase 更新、自动上游分支和版本库安全钩子。"
print "下一步：./Scripts/git-sync.sh"
