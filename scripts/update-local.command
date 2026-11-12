#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
log_dir="$HOME/Library/Logs"
log_file="$log_dir/Kumquat-Local-Update.log"
mkdir -p "$log_dir"
exec >>"$log_file" 2>&1
print "\n[$(date '+%Y-%m-%d %H:%M:%S')] Kumquat local update başladı"

pid="${1:-}"
if [[ -n "$pid" ]]; then
  for _ in {1..100}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi

cd "$repo_dir"
if [[ -n "$(git status --porcelain)" ]]; then
  print -u2 "Yerel repo temiz değil; güvenli güncelleme iptal edildi."
  exit 1
fi
git fetch origin main
if ! git rebase origin/main; then
  git rebase --abort || true
  print -u2 "Upstream değişiklikleri plugin host ile çakıştı; eski çalışan sürüm korundu."
  exit 1
fi
scripts/install-local.sh
print "[$(date '+%Y-%m-%d %H:%M:%S')] Güncelleme tamamlandı"
