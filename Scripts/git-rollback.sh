#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
target="${1:-}"
if [[ -z "$target" ]]; then
  print -u2 "用法：./Scripts/git-rollback.sh <提交号或标签>"
  print -u2 "先用 git log --oneline --decorate 查看可恢复的版本。"
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "工作区尚有未保存改动；为避免覆盖，已停止回滚。"
  exit 1
fi
git rev-parse --verify "$target^{commit}" >/dev/null

short="$(git rev-parse --short "$target^{commit}")"
safety="backup/before-rollback-$(date +%Y%m%d-%H%M%S)"
git branch "$safety"
git restore --source="$target" --staged --worktree -- .
if git diff --cached --quiet; then
  print "当前文件已与 $short 一致，无需创建回滚提交。"
  git branch -D "$safety" >/dev/null
  exit 0
fi
git commit -m "revert: restore project files to $short"

print "已创建可审查的回滚提交：$(git rev-parse --short HEAD)"
print "回滚前的状态仍保存在本地分支：$safety"
print "确认后运行 git push；若不要此回滚，可再对回滚提交执行 git revert HEAD。"
