#!/bin/bash
#
# Soak the editor. Builds once, then loops seeds through the hosted test
# bundle with `test-without-building`, collecting a failure bundle per seed.
#
#   Scripts/fuzz.sh --seeds 1-50 --steps 3000 --profile mixed
#   Scripts/fuzz.sh --seeds 1,7,42 --corpus node-fs-api --profile destroyer
#   Scripts/fuzz.sh --seeds 1-20 --app        # the CLI path, no XCTest
#
# Bundles land under build/fuzz/<corpus>-<profile>-<seed>/ with initial.md,
# ops.jsonl (written ahead of each op, so a crash still names it),
# failure.json, before/after.md, storage.txt and repro.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$HERE/../SwiftProseDemo.xcodeproj"
REPO="$(cd "$HERE/../../.." && pwd)"
DD="${SWIFTPROSE_DERIVED_DATA:-$REPO/build/dd}"
OUT="${SWIFTPROSE_FUZZ_OUT:-$REPO/build/fuzz}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

seeds="1-10"
steps=1000
profile="mixed"
corpus=""
use_app=0
skip_build=0

while [ $# -gt 0 ]; do
  case "$1" in
    --seeds) seeds="$2"; shift 2 ;;
    --steps) steps="$2"; shift 2 ;;
    --profile) profile="$2"; shift 2 ;;
    --corpus) corpus="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --app) use_app=1; shift ;;
    --no-build) skip_build=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

expand_seeds() {
  case "$1" in
    *-*) seq "${1%%-*}" "${1##*-}" ;;
    *) echo "$1" | tr ',' '\n' ;;
  esac
}

mkdir -p "$OUT"

if [ "$skip_build" = 0 ]; then
  echo "==> building once"
  xcodebuild build-for-testing \
    -project "$PROJECT" -scheme SwiftProseDemo \
    -destination 'platform=macOS' -derivedDataPath "$DD" \
    > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
fi

failed=0
total=0

if [ "$use_app" = 1 ]; then
  # One process, every seed. Fastest, and the only mode that survives a
  # crash usefully — the write-ahead log names the op that did it.
  APP="$DD/Build/Products/Debug/SwiftProseDemo.app/Contents/MacOS/SwiftProseDemo"
  args=(--harness fuzz --seeds "$seeds" --steps "$steps" --profile "$profile" --out "$OUT")
  [ -n "$corpus" ] && args+=(--corpus "$corpus")
  "$APP" "${args[@]}"
  status=$?
  # A trap takes the process down mid-run. The bundle path was printed
  # before the first op and the write-ahead log's last line is the op that
  # did it, so say where to look rather than leaving a bare signal.
  if [ "$status" -gt 128 ]; then
    echo
    echo "==> the run TRAPPED (signal $((status - 128)))."
    last="$(ls -td "$OUT"/*/ 2>/dev/null | head -1)"
    if [ -n "$last" ]; then
      echo "    bundle:   $last"
      echo "    last op:  $(tail -1 "$last/ops.jsonl" 2>/dev/null)"
      echo "    shrink:   $APP --harness replay --bundle ${last%/} --shrink --expect crash"
    fi
  fi
  exit $status
fi

for seed in $(expand_seeds "$seeds"); do
  total=$((total + 1))
  echo "==> seed $seed (profile $profile, $steps steps)"
  log="$OUT/seed-$seed.log"
  env \
    TEST_RUNNER_SWIFTPROSE_FUZZ_SEED="$seed" \
    TEST_RUNNER_SWIFTPROSE_FUZZ_STEPS="$steps" \
    TEST_RUNNER_SWIFTPROSE_FUZZ_PROFILE="$profile" \
    TEST_RUNNER_SWIFTPROSE_FUZZ_CORPUS="$corpus" \
    TEST_RUNNER_SWIFTPROSE_FUZZ_OUT="$OUT" \
    xcodebuild test-without-building \
      -project "$PROJECT" -scheme SwiftProseDemo \
      -destination 'platform=macOS' -derivedDataPath "$DD" \
      -only-testing:SwiftProseDemoTests/FuzzTests/testSmokeOverBuiltInFixtures \
      > "$log" 2>&1
  if [ $? -ne 0 ]; then
    failed=$((failed + 1))
    echo "    FAILED — $log"
    grep -E "^\[|bundle:|shrank to|replay:" "$log" | head -20 | sed 's/^/    /'
  else
    grep -E "latency" "$log" | head -1 | sed 's/^/    /'
  fi
done

echo
echo "==> $((total - failed))/$total seeds clean; bundles under $OUT"
[ "$failed" -eq 0 ]
