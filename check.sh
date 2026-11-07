#!/bin/bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILES=()
for f in "$SCRIPT_DIR"/*.sh; do
  FILES+=("$f")
done

exit_code=0

docker run --rm --user "$(id -u):$(id -g)" -v "$SCRIPT_DIR:$SCRIPT_DIR" --workdir "$SCRIPT_DIR" mvdan/shfmt -i 2 -w "${FILES[@]}" || exit_code=1
docker run --rm -v "$SCRIPT_DIR:$SCRIPT_DIR" -w "$SCRIPT_DIR" koalaman/shellcheck "${FILES[@]}" || exit_code=$?

exit $exit_code
