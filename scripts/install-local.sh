#!/bin/zsh
set -euo pipefail

repo_dir="${0:A:h:h}"
plugin_source="$repo_dir/LocalPlugins/har-json-tools"
plugin_root="$HOME/Library/Application Support/Kumquat/Plugins/har-json-tools"
host_root="$HOME/Library/Application Support/Kumquat/PluginHost"
tool_core="$HOME/CascadeProjects/HAR Minifier/har_kucultucu.py"
installed_app="/Applications/Kumquat.app"
backup_root="$HOME/Backups/Kumquat"
stamp="$(date +%Y%m%d-%H%M%S)"

if [[ ! -f "$tool_core" ]]; then
  print -u2 "HAR + JSON core bulunamadı: $tool_core"
  exit 1
fi

cd "$repo_dir"
if [[ "${1:-}" != "--use-existing-build" ]]; then
  swift test --filter ExternalPluginTests
  UNIVERSAL=0 scripts/build-app.sh
fi

build_app="$repo_dir/build/Kumquat.app"
if [[ ! -x "$build_app/Contents/MacOS/Kumquat" ]]; then
  print -u2 "Derlenmiş Kumquat bulunamadı: $build_app"
  exit 1
fi

mkdir -p "$HOME/Library/Application Support/Kumquat/Plugins" "$host_root" "$backup_root"
if [[ -e "$plugin_root" ]]; then
  trash "$plugin_root"
fi
ditto "$plugin_source" "$plugin_root"
mkdir -p "$plugin_root/lib"
ditto "$tool_core" "$plugin_root/lib/har_kucultucu.py"
chmod 755 "$plugin_root/bin/kumquat-har-json-tools"
ln -sfn "$repo_dir/scripts/update-local.command" "$host_root/update.command"

osascript -e 'tell application id "io.github.iandifilippo.kumquat" to quit' >/dev/null 2>&1 || true
for _ in {1..50}; do
  pgrep -x Kumquat >/dev/null || break
  sleep 0.1
done
if pgrep -x Kumquat >/dev/null; then
  print -u2 "Kumquat kapanmadı; mevcut uygulamaya dokunulmadı."
  exit 1
fi

backup_app=""
if [[ -d "$installed_app" ]]; then
  version="$(defaults read "$installed_app/Contents/Info" CFBundleShortVersionString 2>/dev/null || print unknown)"
  backup_app="$backup_root/Kumquat-$version-before-plugin-$stamp.app"
  mv "$installed_app" "$backup_app"
fi

restore_previous() {
  if [[ ! -d "$installed_app" && -n "$backup_app" && -d "$backup_app" ]]; then
    mv "$backup_app" "$installed_app"
  fi
}
trap restore_previous ERR INT TERM
ditto "$build_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"
trap - ERR INT TERM

open "$installed_app"
print "Kumquat plugin host kuruldu."
print "Plugin: $plugin_root"
[[ -n "$backup_app" ]] && print "Önceki uygulama yedeği: $backup_app"
