#!/usr/bin/env bash

set -euo pipefail

mode="${1:-run}"
app_name="Montazhka"
bundle_id="ru.ungurenko.montazhka"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_bundle="$root_dir/build.noindex/Монтажка.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"

stop_running_app() {
  pkill -x "$app_name" >/dev/null 2>&1 || true
}

build_app() {
  "$root_dir/scripts/build-app.sh" --adhoc
}

open_app() {
  /usr/bin/open -n "$app_bundle"
}

verify_process() {
  local attempt pid command
  for attempt in {1..40}; do
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      if [[ "$command" == "$app_binary"* ]]; then
        echo "✓ $app_name запущена из $app_bundle (PID $pid)"
        return 0
      fi
    done < <(pgrep -x "$app_name" 2>/dev/null || true)
    sleep 0.25
  done
  echo "✗ $app_name не запустилась из свежей сборки $app_bundle" >&2
  return 1
}

case "$mode" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

stop_running_app
build_app

case "$mode" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$app_binary"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$app_name\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$bundle_id\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
esac
