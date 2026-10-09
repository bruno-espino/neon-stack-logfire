#!/bin/sh
set -eu
trap 'exit 130' INT
app=''
probe=''
repetitions=5
local_flag=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-telemetry) local_flag=--no-telemetry; shift ;;
        --app|--probe|--repeat)
            if [ "$#" -lt 2 ]; then printf 'Missing value for %s\n' "$1" >&2; exit 2; fi
            case "$1" in --app) app=$2 ;; --probe) probe=$2 ;; --repeat) repetitions=$2 ;; esac
            shift 2 ;;
        --help)
            printf 'Usage: tools/check-preview.sh --app NeonStack.app --probe PresentationProbe.app [--repeat 5] [--no-telemetry]\n'
            printf 'Run reference-game and presentation policies, retain all failures, and check local evidence. This is an opt-in dashboard audit.\n'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
case "$repetitions" in 1|2|3|4|5) ;; *) printf 'Use --repeat between 1 and 5.\n' >&2; exit 2 ;; esac
if [ ! -d "$app" ] || [ ! -d "$probe" ]; then printf 'Supply both built application bundles.\n' >&2; exit 2; fi
app=$(CDPATH= cd -- "$app" && pwd)
probe=$(CDPATH= cd -- "$probe" && pwd)
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tools/xcode-env.sh"
cd "$root"
products=$(/usr/bin/xcrun swift build --show-bin-path)
cli="$products/logfire-apple"
if [ ! -x "$cli" ]; then printf 'Build logfire-apple before this audit.\n' >&2; exit 2; fi
umask 077
output="$root/.xcode-observe/preview-verification/$(uuidgen)"
mkdir -p "$output"
printf 'Preview evidence: %s\n' "$output"
printf 'case\texit_code\n' > "$output/cases.tsv"
run_case() {
    label=$1
    bundle=$2
    scenario=$3
    deadline=$4
    code=0
    "$cli" run --app "$bundle" --scenario "$scenario" --seconds "$deadline" \
        --output "$output/$label" $local_flag > "$output/$label.log" 2>&1 || code=$?
    printf '%s\t%s\n' "$label" "$code" >> "$output/cases.tsv"
    printf '%s exit %s\n' "$label" "$code"
    case "$code" in 130|143) exit "$code" ;; esac
}
i=1
while [ "$i" -le "$repetitions" ]; do
    run_case "$i-normal" "$probe" "$root/examples/presentation-probe/scenarios/normal.json" 20
    run_case "$i-half-rate" "$probe" "$root/examples/presentation-probe/scenarios/half-rate.json" 20
    run_case "$i-bounded" "$app" "$root/examples/neon-stack/scenarios/log-roll-hud-bounded.json" 20
    run_case "$i-every-frame" "$app" "$root/examples/neon-stack/scenarios/log-roll-hud-every-frame.json" 20
    run_case "$i-gpu-high" "$app" "$root/examples/neon-stack/scenarios/log-roll-gpu-high.json" 20
    i=$((i + 1))
done
run_case continuous "$probe" "$root/examples/presentation-probe/scenarios/continuous.json" 75
i=1
while [ "$i" -le "$repetitions" ]; do
    /usr/bin/xcrun swift "$root/tools/check-presentation.swift" "$output/$i-normal" "$output/$i-half-rate"
    i=$((i + 1))
done
/usr/bin/xcrun swift "$root/tools/check-preview.swift" "$output" "$repetitions" ${local_flag:+--no-telemetry}
printf 'Local preview audit passed. Reconcile these sessions with hosted records and metrics before claiming complete delivery.\n'
