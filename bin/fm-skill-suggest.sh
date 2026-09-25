#!/usr/bin/env bash
# fm-skill-suggest.sh - pick at most one agent-only skill with Jev, opt-in.
#
# Usage:
#   fm-skill-suggest.sh --ask <file> [--skills-dir <dir>]
#
# Opt-in gate: same TYPESAFE_API_KEY contract as bin/fm-dispatch-resolve.sh.
#   Absent: one "skill-suggest: off" line on stderr, exit 0, no network call.
#
# When on: reads each SKILL.md under --skills-dir (default
#   $FM_ROOT/.agents/skills), takes `name` and `description` from the YAML
#   front matter, and sends one POST with:
#     needs_skill  Noul: whether this turn should load a skill
#     skill        Choice: each catalog name plus `none`
#   Code loads a skill only on clear + needs_skill >= 0.6 + skill != none.
#   docs/configuration.md "Typed skill suggestion" owns the operator contract.
#
# Output (stdout):
#   skill-suggest:
#     status: clear | none | ambiguous | error
#     skill: <name> | none
#     needs_skill: <probability>
#     confidence: <Choice confidence>
#   clear     -> load that one skill if it is in the current catalog
#   none      -> load nothing extra; the turn needs no listed skill
#   ambiguous -> below the 0.6 floors; decide as today
#   error     -> API or response failure; decide as today
#   Every outcome exits 0. Exit 2 only for usage or missing jq.
#
# Authority: this tool never replaces a skill's own trigger in AGENTS.md.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

CONFIDENCE_FLOOR=0.6
NEEDS_FLOOR=0.6
TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5

die() { printf 'error: %s\n' "$1" >&2; exit 2; }
usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

ASK='' SKILLS_DIR="$FM_ROOT/.agents/skills"
while [ $# -gt 0 ]; do
  case "$1" in
    --ask) [ $# -ge 2 ] || die "--ask needs a value"; ASK=$2; shift 2 ;;
    --skills-dir) [ $# -ge 2 ] || die "--skills-dir needs a value"; SKILLS_DIR=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) die "unexpected argument $1" ;;
  esac
done

if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "skill-suggest: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

[ -n "$ASK" ] || die "ask file required (see --help)"
[ -r "$ASK" ] || die "ask file not readable: $ASK"
[ -d "$SKILLS_DIR" ] || die "skills directory not found: $SKILLS_DIR"
command -v jq >/dev/null 2>&1 || die "jq required"

CATALOG=$(mktemp) || die "mktemp failed"
RESP_FILE=$(mktemp) || { rm -f "$CATALOG"; die "mktemp failed"; }
trap 'rm -f "$CATALOG" "$RESP_FILE"' EXIT

: > "$CATALOG"
for skill_md in "$SKILLS_DIR"/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  awk '
    BEGIN { fm=0; name=""; desc=""; indesc=0 }
    /^---[[:space:]]*$/ { fm++; next }
    fm != 1 { next }
    /^name:[[:space:]]*/ {
      name=$0; sub(/^name:[[:space:]]*/, "", name)
      next
    }
    /^description:[[:space:]]*/ {
      indesc=1
      line=$0
      sub(/^description:[[:space:]]*/, "", line)
      sub(/^>-[[:space:]]*/, "", line)
      sub(/^>[[:space:]]*/, "", line)
      desc=line
      next
    }
    indesc && /^[A-Za-z0-9_]+:/ { indesc=0 }
    indesc { desc = desc " " $0 }
    END {
      gsub(/[[:space:]]+/, " ", desc)
      if (name != "") print name "\t" desc
    }
  ' "$skill_md" >> "$CATALOG" || die "could not read $skill_md"
done

[ -s "$CATALOG" ] || die "no SKILL.md files under $SKILLS_DIR"

emit_error() {
  local reason=$1
  echo "skill-suggest: error ($reason)" >&2
  printf 'skill-suggest:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

command -v curl >/dev/null 2>&1 || emit_error "curl not installed"

REQUEST=$(jq -n --rawfile ask "$ASK" --rawfile catalog "$CATALOG" --arg model "$TS_MODEL" '
  ($catalog | split("\n") | map(select(length > 0) | split("\t")) | map(select(length >= 1) | {name: .[0], description: (.[1] // "")})) as $skills |
  ($skills | map({key: .name, value: (.description)}) | from_entries) as $crit |
  {
    model: $model,
    state: {ask: $ask, skills: $skills},
    questions: {
      needs_skill: {
        type: "noul",
        instructions: "Does `ask` require loading one of the listed agent-only skills this turn?",
        criteria: {
          true: "A listed skill trigger matches the ask and that skill should load this turn.",
          false: "Ordinary firstmate procedure is enough, or no listed skill applies."
        }
      },
      skill: {
        type: "choice",
        instructions: "Which ONE listed skill should be loaded for `ask`? Pick `none` when no listed skill should load.",
        criteria: ($crit + {none: "No listed skill should be loaded for this ask."})
      }
    }
  }')

LAT_MS=null
T0=$(fm_timing_now_ms)
HTTP=$(printf '%s' "$REQUEST" | curl -sS --max-time "$TS_TIMEOUT" -o "$RESP_FILE" -w '%{http_code}' \
  -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
  -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
  --data-binary @- 2>/dev/null) || HTTP=000
T1=$(fm_timing_now_ms)
LAT_MS=$(( T1 - T0 ))
[ "$HTTP" = 200 ] || emit_error "http $HTTP after ${LAT_MS} ms: $(head -c 200 "$RESP_FILE" 2>/dev/null | tr '\n' ' ')"

SKILL_KEYS=$(awk -F '\t' 'NF { print $1 }' "$CATALOG" | jq -Rsc 'split("\n") | map(select(length > 0)) + ["none"]')
jq -e --argjson skills "$SKILL_KEYS" '
  ((.answers.needs_skill.probability // .answers.needs_skill.noul) | type) == "number" and
  (.answers.skill.choice | type) == "string" and
  ((.answers.skill.probabilities | keys | sort) == ($skills | sort))
' "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not a skill-suggestion answer"

jq -r --argjson lat "$LAT_MS" --argjson floor "$CONFIDENCE_FLOOR" --argjson needs_floor "$NEEDS_FLOOR" '
  . as $r |
  ($r.answers.skill) as $s |
  ($r.answers.needs_skill.probability // $r.answers.needs_skill.noul) as $need |
  (if ($s.confidence < $floor) then "ambiguous"
   elif $need < $needs_floor or $s.choice == "none" then "none"
   else "clear" end) as $status |
  (if $status == "ambiguous" then "confidence \($s.confidence) below \($floor)"
   elif $status == "none" then "no listed skill should load"
   else "ok" end) as $reason |
  "skill-suggest:",
  "  status: \($status)",
  "  skill: \($s.choice)",
  "  needs_skill: \($need)",
  "  confidence: \($s.confidence)",
  "  latency_ms: \($lat)",
  "  reason: \($reason)"
' "$RESP_FILE"

exit 0
