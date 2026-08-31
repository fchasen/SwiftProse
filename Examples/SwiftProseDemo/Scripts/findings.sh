#!/bin/bash
#
# Everything the harness currently knows is wrong with the editor, read
# straight out of the scenario catalogue so it can't go stale:
#
#   crashes  — the scenario traps the process; ScenarioTests skips it and
#              the fuzz smoke stands down while any of these is open
#   xfail    — the scenario asserts correct behaviour the editor does not
#              have; the runner checks it still fails the same way
#
# Fix one, delete the field, and the suite tells you if you were right.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/findings.py" "$HERE/../SwiftProseDemo/Fixtures/scenarios" "$@"
