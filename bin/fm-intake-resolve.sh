#!/usr/bin/env bash
# fm-intake-resolve.sh - classify one captain ask with typesafe.ai Jev, opt-in.
#
# Usage:
#   fm-intake-resolve.sh --ask <file> [--projects <registry>]
#
# Opt-in gate: same TYPESAFE_API_KEY contract as bin/fm-dispatch-resolve.sh
#   (environment wins, else $FM_HOME/.env via fmx_env_get). Absent: one
#   "intake-resolve: off" line on stderr, exit 0, no network call.
#
# When on: one POST to https://api.typesafe.ai/v1/systemone with the ask text
#   and the registered project names as state, plus four questions in one
#   request (intent-routing / speculative fan-out):
#     deliverable  Choice: ship | scout | answer | unclear
#     effort       Choice: low | medium | high | xhigh
#     project      Choice: each registry name | none | unclear
#     ask_captain  Noul: whether the ask needs a clarifying question first
#   Code owns thresholds. The model never sees delivery mode, yolo, or quota.
#   docs/configuration.md "Typed intake resolution" owns the operator contract.
#
# Output (stdout):
#   intake-resolve:
#     status: clear | ambiguous | escalate | error
#     deliverable / effort / project / ask_captain
#     confidence: <min of the three Choice confidences>
#     reason: <when status is not clear>
#   clear     -> firstmate may use the fields as intake hints
#   ambiguous -> below the 0.6 confidence floor; decide as today
#   escalate  -> ask_captain probability >= 0.6 or deliverable/project unclear
#   error     -> API or response failure; decide as today
#   Every outcome exits 0. Exit 2 only for usage or missing jq.
#
# Authority: this tool never replaces AGENTS.md section 7 intake judgment.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"

CONFIDENCE_FLOOR=0.6
ASK_CAPTAIN_FLOOR=0.6
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

ASK='' PROJECTS="$DATA/projects.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --ask) [ $# -ge 2 ] || die "--ask needs a value"; ASK=$2; shift 2 ;;
    --projects) [ $# -ge 2 ] || die "--projects needs a value"; PROJECTS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown flag $1" ;;
    *) die "unexpected argument $1" ;;
  esac
done

if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  echo "intake-resolve: off (TYPESAFE_API_KEY absent from the environment and $FM_HOME/.env)" >&2
  exit 0
fi

[ -n "$ASK" ] || die "ask file required (see --help)"
[ -r "$ASK" ] || die "ask file not readable: $ASK"
command -v jq >/dev/null 2>&1 || die "jq required"

NAMES=$(mktemp) || die "mktemp failed"
RESP_FILE=$(mktemp) || { rm -f "$NAMES"; die "mktemp failed"; }
trap 'rm -f "$NAMES" "$RESP_FILE"' EXIT

if [ -f "$PROJECTS" ]; then
  awk '
    $1 == "-" && $2 != "" { print $2 }
  ' "$PROJECTS" | awk 'NF && !seen[$0]++' > "$NAMES" || die "could not read registry: $PROJECTS"
else
  : > "$NAMES"
fi

emit_error() {
  local reason=$1
  echo "intake-resolve: error ($reason)" >&2
  printf 'intake-resolve:\n  status: error\n  reason: %s\n' "$reason"
  exit 0
}

command -v curl >/dev/null 2>&1 || emit_error "curl not installed"

REQUEST=$(jq -n --rawfile ask "$ASK" --rawfile names "$NAMES" --arg model "$TS_MODEL" '
  ($names | split("\n") | map(select(length > 0))) as $projects |
  ($projects | map({key: ., value: ("The registered project named " + .)}) | from_entries) as $proj_crit |
  {
    model: $model,
    state: {ask: $ask, registered_projects: $projects},
    questions: {
      deliverable: {
        type: "choice",
        instructions: "What deliverable does `ask` request? Pick `ship` for an authorized project change, `scout` for a knowledge-only report, `answer` when established evidence or a short reply is enough, or `unclear` when that choice is not safe.",
        criteria: {
          ship: "The captain wants a change implemented in a project.",
          scout: "The captain wants investigation, diagnosis, planning, or an audit report rather than a change.",
          answer: "The ask can be answered in conversation without dispatching a worker.",
          unclear: "The ask does not make the deliverable clear."
        }
      },
      effort: {
        type: "choice",
        instructions: "What reasoning effort does `ask` need if a worker is dispatched? Never pick a higher tier than the work requires.",
        criteria: {
          low: "Well-understood, bounded, explicit work.",
          medium: "Ordinary feature or fix work with some judgment.",
          high: "Ambiguous, multi-file, or high-blast-radius work.",
          xhigh: "Open-ended investigation or design that could change what to build."
        }
      },
      project: {
        type: "choice",
        instructions: "Which registered project does `ask` refer to? Pick `none` when no registry entry fits, or `unclear` when more than one could fit.",
        criteria: ($proj_crit + {
          none: "No listed project matches this ask.",
          unclear: "Two or more listed projects could match, or the referent is ambiguous."
        })
      },
      ask_captain: {
        type: "noul",
        instructions: "Does `ask` require a clarifying question before firstmate can safely classify the project or deliverable?",
        criteria: {
          true: "More than one project could match, the deliverable is unclear, or a destructive or irreversible reading is plausible.",
          false: "The project and deliverable are clear enough to classify without a clarifying question."
        }
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

PROJ_KEYS=$(jq -Rsc 'split("\n") | map(select(length > 0)) + ["none","unclear"]' < "$NAMES")
jq -e --argjson projects "$PROJ_KEYS" '
  (.answers.deliverable.choice | type) == "string" and
  (.answers.effort.choice | type) == "string" and
  (.answers.project.choice | type) == "string" and
  ((.answers.ask_captain.probability // .answers.ask_captain.noul) | type) == "number" and
  ((.answers.deliverable.probabilities | keys | sort) == (["answer","scout","ship","unclear"] | sort)) and
  ((.answers.effort.probabilities | keys | sort) == (["high","low","medium","xhigh"] | sort)) and
  ((.answers.project.probabilities | keys | sort) == ($projects | sort))
' "$RESP_FILE" >/dev/null 2>&1 || emit_error "response is not an intake answer"

jq -r --argjson lat "$LAT_MS" --argjson floor "$CONFIDENCE_FLOOR" --argjson ask_floor "$ASK_CAPTAIN_FLOOR" '
  . as $r |
  ($r.answers.deliverable) as $d |
  ($r.answers.effort) as $e |
  ($r.answers.project) as $p |
  ($r.answers.ask_captain.probability // $r.answers.ask_captain.noul) as $ask |
  ([$d.confidence, $e.confidence, $p.confidence] | min) as $conf |
  (if $ask >= $ask_floor or $d.choice == "unclear" or $p.choice == "unclear" then "escalate"
   elif $conf < $floor then "ambiguous"
   else "clear" end) as $status |
  (if $status == "escalate" then
     (if $ask >= $ask_floor then "ask needs a clarifying question"
      elif $d.choice == "unclear" then "deliverable is unclear"
      else "project is unclear" end)
   elif $status == "ambiguous" then "confidence \($conf) below \($floor)"
   else "ok" end) as $reason |
  "intake-resolve:",
  "  status: \($status)",
  "  deliverable: \($d.choice)",
  "  effort: \($e.choice)",
  "  project: \($p.choice)",
  "  ask_captain: \($ask)",
  "  confidence: \($conf)",
  "  latency_ms: \($lat)",
  "  reason: \($reason)"
' "$RESP_FILE"

exit 0
