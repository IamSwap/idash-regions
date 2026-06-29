#!/usr/bin/env bash
# Build the offline place-search index (search.sqlite) for EVERY state in states.tsv, then regenerate
# the catalog and publish. Idempotent: skips states that already have a search index. Continues past
# a single state's failure (logged), so one missing OSM extract doesn't abort the batch.
#
# Usage: ./build-all-search.sh          (build missing + publish)
#        PUSH=0 ./build-all-search.sh   (build + commit, no push)
set -uo pipefail
cd "$(dirname "$0")"

built=0 skipped=0 failed=()
while IFS=$'\t' read -r ID NAME ZONE W S E N MAXZ; do
  case "$ID" in ''|\#*) continue;; esac
  if [ -f "packs/$ID/search.sqlite" ]; then
    echo "== skip $ID (search.sqlite exists)"; skipped=$((skipped + 1)); continue
  fi
  echo "== build $ID ($NAME)"
  if ./build-search.sh "$ID" "$NAME" "$W" "$S" "$E" "$N" "$ZONE"; then
    built=$((built + 1))
  else
    echo "!! FAILED: $ID"; failed+=("$ID")
  fi
done < states.tsv

echo "── built=$built skipped=$skipped failed=${#failed[@]} ${failed[*]:-}"

echo "── regenerating catalog"
./gen-catalog.sh

echo "── committing search indexes"
git add packs/*/search.sqlite regions.json
if git diff --cached --quiet; then
  echo "no changes to commit."
else
  git commit --author="Swapnil Bhavsar <hey@swapnil.dev>" -q -m "Add offline search indexes for all states"
  if [ "${PUSH:-1}" = 1 ]; then
    git push origin HEAD && echo "published → origin"
  else
    echo "PUSH=0 — committed locally, not pushed."
  fi
fi
echo "── done"
