#!/usr/bin/env bash
# Behavior tests for bin/fm-intake-resolve.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-intake-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-intake-resolve)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ASK="$TMP_ROOT/ask.txt"
PROJECTS="$TMP_ROOT/projects.md"
RESP="$TMP_ROOT/resp.json"
mkdir -p "$HOME_DIR"

cat > "$ASK" <<'TXT'
Fix the pager off-by-one in firstmate.
TXT

cat > "$PROJECTS" <<'MD'
- firstmate - supervisor (added 2026-01-01)
- other - other work (added 2026-01-01)
MD

cat > "$RESP" <<'JSON'
{
  "model": "jev-1.13.0",
  "answers": {
    "deliverable": {
      "type": "choice",
      "choice": "ship",
      "confidence": 0.91,
      "probabilities": {"ship": 0.91, "scout": 0.04, "answer": 0.03, "unclear": 0.02}
    },
    "effort": {
      "type": "choice",
      "choice": "low",
      "confidence": 0.88,
      "probabilities": {"low": 0.88, "medium": 0.08, "high": 0.03, "xhigh": 0.01}
    },
    "project": {
      "type": "choice",
      "choice": "firstmate",
      "confidence": 0.86,
      "probabilities": {"firstmate": 0.86, "other": 0.08, "none": 0.04, "unclear": 0.02}
    },
    "ask_captain": {"type": "noul", "probability": 0.11}
  }
}
JSON

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat "${FAKE_CURL_RESPONSE:?}" > "$out"
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

export PATH="$FAKEBIN:$PATH"
export FM_HOME="$HOME_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
export FAKE_CURL_RESPONSE="$RESP"
export FAKE_CURL_HTTP=200

out=$( "$TOOL" --ask "$ASK" --projects "$PROJECTS" 2>"$TMP_ROOT/err" || true )
assert_contains "$(cat "$TMP_ROOT/err")" 'intake-resolve: off' "absent key stays off"
assert_equals '' "$out" "absent key prints nothing on stdout"

out=$( TYPESAFE_API_KEY=test-key "$TOOL" --ask "$ASK" --projects "$PROJECTS" 2>"$TMP_ROOT/err" )
assert_contains "$out" 'status: clear' "high-confidence intake is clear"
assert_contains "$out" 'deliverable: ship' "deliverable is ship"
assert_contains "$out" 'project: firstmate' "project matches the registry"

python3 - <<'PY' "$RESP"
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["answers"]["ask_captain"]["probability"] = 0.72
p.write_text(json.dumps(data))
PY

out=$( TYPESAFE_API_KEY=test-key "$TOOL" --ask "$ASK" --projects "$PROJECTS" 2>/dev/null )
assert_contains "$out" 'status: escalate' "high ask_captain escalates"
pass "intake-resolve public interface"
