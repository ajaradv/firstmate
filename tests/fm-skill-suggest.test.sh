#!/usr/bin/env bash
# Behavior tests for bin/fm-skill-suggest.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-skill-suggest.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-suggest)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ASK="$TMP_ROOT/ask.txt"
SKILLS="$TMP_ROOT/skills"
RESP="$TMP_ROOT/resp.json"
mkdir -p "$HOME_DIR" "$SKILLS/stow" "$SKILLS/bearings"

cat > "$ASK" <<'TXT'
Stow what you have learned this session.
TXT

cat > "$SKILLS/stow/SKILL.md" <<'MD'
---
name: stow
description: Sweep session knowledge to disk.
---
# stow
MD

cat > "$SKILLS/bearings/SKILL.md" <<'MD'
---
name: bearings
description: Fleet catch-up digest.
---
# bearings
MD

cat > "$RESP" <<'JSON'
{
  "model": "jev-1.13.0",
  "answers": {
    "needs_skill": {"type": "noul", "probability": 0.93},
    "skill": {
      "type": "choice",
      "choice": "stow",
      "confidence": 0.9,
      "probabilities": {"stow": 0.9, "bearings": 0.06, "none": 0.04}
    }
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

out=$( "$TOOL" --ask "$ASK" --skills-dir "$SKILLS" 2>"$TMP_ROOT/err" || true )
assert_contains "$(cat "$TMP_ROOT/err")" 'skill-suggest: off' "absent key stays off"
assert_equals '' "$out" "absent key prints nothing on stdout"

out=$( TYPESAFE_API_KEY=test-key "$TOOL" --ask "$ASK" --skills-dir "$SKILLS" 2>/dev/null )
assert_contains "$out" 'status: clear' "matching skill is clear"
assert_contains "$out" 'skill: stow' "stow is selected"

python3 - <<'PY' "$RESP"
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
data["answers"]["needs_skill"]["probability"] = 0.12
data["answers"]["skill"]["choice"] = "none"
data["answers"]["skill"]["probabilities"] = {"stow": 0.1, "bearings": 0.1, "none": 0.8}
p.write_text(json.dumps(data))
PY

out=$( TYPESAFE_API_KEY=test-key "$TOOL" --ask "$ASK" --skills-dir "$SKILLS" 2>/dev/null )
assert_contains "$out" 'status: none' "low needs_skill stays none"
pass "skill-suggest public interface"
