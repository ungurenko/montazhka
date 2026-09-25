#!/bin/sh
set -eu

case "${1:-}" in
  one) exec montazhka edit-video --input "$2" --profile clean-speech ;;
  multiple) exec montazhka edit-video --input "$2" --input "$3" --profile dynamic ;;
  smart) exec montazhka edit-video --input "$2" --profile clean-speech --smart-edit ;;
  exact-cuts) exec montazhka edit-project --request "$2" ;;
  shorts) exec montazhka make-shorts --request "$2" ;;
  resume) exec montazhka job --id "$2" ;;
  draft) exec montazhka export --project "$2" --quality compact ;;
  final) exec montazhka export --project "$2" --quality high --final --confirm-final ;;
  transcript) exec montazhka transcript --project "$2" ;;
  frames) exec montazhka frames --project "$2" --from "$3" --to "$4" --count 8 ;;
  cuts) exec montazhka frames --project "$2" --around-cuts ;;
  audio) exec montazhka audio --project "$2" --buckets 60 ;;
  edits) exec montazhka apply-edits --project "$2" --request "$3" ;;
  undo) exec montazhka apply-edits --project "$2" --undo 1 ;;
  *) echo "Использование: $0 one|multiple|smart|exact-cuts|shorts|resume|draft|final|transcript|frames|cuts|audio|edits|undo ..." >&2; exit 2 ;;
esac
