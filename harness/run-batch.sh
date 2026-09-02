#!/usr/bin/env sh
# Run the harness profile's scenarios under plain batch ERT, with no
# container (emacs-harness DESIGN.md 8.1: a scenario file is Emacs Lisp
# and runs inside the instance under test, so the same file also runs
# under `ert-run-tests-batch-and-exit').
#
#   harness/run-batch.sh [--harness DIR] [ERT-SELECTOR]
#
# This is the fast edit/run loop, NOT a substitute for `harness/run.sh':
# every scenario tagged `visual' or needing a graphical frame skips here,
# which is most of what the harness exists for. Use it to get tier-1
# assertions right, then run the container before believing anything.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
harness=${EMACS_HARNESS:-$repo/../emacs-harness}
selector='(tag eh-scenario)'

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) harness=$(cd "$2" && pwd); shift 2 ;;
    *) selector=$1; shift ;;
  esac
done

if [ ! -d "$harness/elisp" ]; then
  echo "harness/run-batch.sh: no emacs-harness checkout at $harness" >&2
  echo "  clone https://github.com/EGuthrieWasTaken/emacs-harness and pass" >&2
  echo "  --harness DIR, or set EMACS_HARNESS." >&2
  exit 2
fi

profile=$repo/harness/profile
work=${TMPDIR:-/tmp}/jsonyter-harness-batch
rm -rf "$work"
mkdir -p "$work/scratch"

set -- \
  -Q --batch \
  -L "$harness/elisp" \
  --eval "(setq eh-run-dir \"$work\"
                eh-profile-dir \"$profile\"
                eh-profile-fixtures-dir \"$profile/fixtures\"
                eh-profile-bridge-scripts-dir \"$profile/bridge-scripts\"
                eh-profile-scratch-dir \"$work/scratch\"
                eh-fake-bridge \"$harness/bin/eh-fake-bridge\")" \
  -l eh-driver -l eh-scenario -l eh-profile \
  -l "$profile/init.el"

for file in "$profile"/scenarios/*.el; do
  set -- "$@" -l "$file"
done

JSONYTER_SRC=$repo exec emacs "$@" \
  --eval "(ert-run-tests-batch-and-exit '$selector)"
