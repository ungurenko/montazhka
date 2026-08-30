#!/bin/sh
set -eu

case "${1:-}" in
  one) exec montazhka edit-video --input "$2" --profile clean-speech ;;
  multiple) exec montazhka edit-video --input "$2" --input "$3" --profile dynamic ;;
  smart) exec montazhka edit-video --input "$2" --profile clean-speech --smart-edit ;;
  exact-cuts) exec montazhka edit-project --request "$2" ;;
  shorts) exec montazhka make-shorts --input "$2" ;;
  resume) exec montazhka job --id "$2" ;;
  draft) exec montazhka export --project "$2" --quality compact ;;
  final) exec montazhka export --project "$2" --quality high --final --confirm-final ;;
  *) echo "Использование: $0 one|multiple|smart|exact-cuts|shorts|resume|draft|final ..." >&2; exit 2 ;;
esac
