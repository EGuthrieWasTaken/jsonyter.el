#!/usr/bin/env sh
# Run jsonyter.el's harness profile in an emacs-harness container.
#
#   harness/run.sh [--harness DIR] [--image NAME] [--build] [-- EH-ARGS...]
#
#   --harness DIR   an emacs-harness checkout (default ../emacs-harness,
#                   or $EMACS_HARNESS)
#   --image NAME    the image to run (default jsonyter-harness:dev)
#   --build         build it first, from the harness checkout plus
#                   harness/Dockerfile
#   --              everything after this goes to `eh' inside the
#                   container, e.g. `-- run jsonyter --scenario X'
#
# The profile lives in *this* repository and is mounted over
# /srv/profiles/jsonyter, and the package is mounted read-only at
# /srv/package -- so a behaviour change and the scenario that covers it
# are one commit in one pull request, and no harness rebuild is needed to
# change either.

set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
harness=${EMACS_HARNESS:-$repo/../emacs-harness}
image=${JSONYTER_HARNESS_IMAGE:-jsonyter-harness:dev}
build=no

while [ $# -gt 0 ]; do
  case "$1" in
    --harness) harness=$2; shift 2 ;;
    --image)   image=$2; shift 2 ;;
    --build)   build=yes; shift ;;
    --)        shift; break ;;
    *)         break ;;
  esac
done

[ $# -gt 0 ] || set -- run jsonyter

if [ ! -d "$harness/container" ]; then
  echo "harness/run.sh: no emacs-harness checkout at $harness" >&2
  echo "  clone https://github.com/EGuthrieWasTaken/emacs-harness and pass" >&2
  echo "  --harness DIR, or set EMACS_HARNESS." >&2
  exit 2
fi

if [ "$build" = yes ]; then
  docker build -t emacs-harness:local -f "$harness/container/Dockerfile" "$harness"
  docker build -t "$image" --build-arg BASE=emacs-harness:local "$repo/harness"
fi

mkdir -p "$repo/runs"

# --shm-size is not optional: X servers use shared memory, and Docker's
# 64MB default is enough to make Xvfb fall over intermittently -- which
# reads as a flaky suite rather than as the configuration problem it is.
exec docker run --rm --shm-size=1gb \
  -v "$repo:/srv/package:ro" \
  -v "$repo/harness/profile:/srv/profiles/jsonyter:ro" \
  -v "$repo/runs:/var/lib/eh/runs" \
  "$image" "$@"
