#!/bin/bash
#
# Rebuild Fixtures/corpus from corpus.json.
#
# Every entry is pinned to a commit, so a re-fetch reproduces the checked-in
# bytes. Adding a document: append an entry with "commit": "HEAD" and run
# this — the script resolves HEAD to the current sha and writes it back, so
# the manifest is always pinned after a run.
#
#   Scripts/make-corpus.sh              # re-fetch everything
#   Scripts/make-corpus.sh --books      # also convert the local books
#   Scripts/make-corpus.sh --check      # verify sizes, fetch nothing
#
# Needs `gh` (for the API rate limit) and, for --books, `pandoc`.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CORPUS="$HERE/../SwiftProseDemo/Fixtures/corpus"
MANIFEST="$CORPUS/corpus.json"
EXTERNAL="$HERE/../SwiftProseDemo/Fixtures-external"
# Cleaned-up local copies; see the manifest for provenance.
BOOKS_SRC="${SWIFTPROSE_BOOKS_SRC:-$HOME/Repos/pagedjs-combo/examples}"

books=0
check=0
for arg in "$@"; do
  case "$arg" in
    --books) books=1 ;;
    --check) check=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

python3 "$HERE/make_corpus.py" \
  --corpus "$CORPUS" \
  --manifest "$MANIFEST" \
  $( [ "$check" = 1 ] && echo --check )

if [ "$books" = 1 ]; then
  mkdir -p "$EXTERNAL"
  # `gfm-raw_html` strips every wrapper tag and keeps headings, emphasis
  # and curly quotes. Alice is checked in; Moby Dick is soak-only and stays
  # out of git.
  if [ -f "$BOOKS_SRC/alice-in-wonderland/index.html" ]; then
    pandoc -f html -t gfm-raw_html --wrap=none \
      "$BOOKS_SRC/alice-in-wonderland/index.html" \
      -o "$CORPUS/alice-in-wonderland.md"
    echo "wrote alice-in-wonderland.md ($(wc -c < "$CORPUS/alice-in-wonderland.md") bytes)"
  fi
  if [ -f "$BOOKS_SRC/moby-dick/index.html" ]; then
    pandoc -f html -t gfm-raw_html --wrap=none \
      "$BOOKS_SRC/moby-dick/index.html" \
      -o "$EXTERNAL/moby-dick.md"
    echo "wrote Fixtures-external/moby-dick.md ($(wc -c < "$EXTERNAL/moby-dick.md") bytes) — gitignored, soak only"
  fi
fi
