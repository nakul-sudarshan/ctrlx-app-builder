#Author: Nakul Sudarshan (with help from Copilot and Claude) 

#!/usr/bin/env bash
# Build every project in a folder of SDK sample projects for amd64 and arm64
# through ctrlx-build.sh, and tabulate the results.
#
# Usage: test-samples.sh <samples-dir> [--lang cpp|dotnet|go|java|node|python] [--arch amd64|arm64|both]
#                        [--only name1,name2]
#
# <samples-dir> holds one folder per project (source + snap/snapcraft.yaml + config).
# The folders are copied to a work directory first, so the originals stay untouched.
# Result states: ok (build and checks passed), warn (build passed, but an ELF file of
# another architecture is inside: reported only, not a failure), FAIL.
# Results: <work-dir>/results.tsv ; builder logs: ctrlx-build/logs/.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SAMPLES=""
LANG_ID=dotnet
ARCHES=(amd64 arm64)
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --lang) LANG_ID=${2:-}; shift 2 ;;
        --arch)
            case "${2:-}" in
                both) ARCHES=(amd64 arm64) ;;
                amd64|arm64) ARCHES=("$2") ;;
                *) echo "ERROR: --arch needs amd64, arm64 or both" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --only) ONLY=${2:-}; shift 2 ;;
        -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) SAMPLES=$1; shift ;;
    esac
done
[ -d "$SAMPLES" ] || { echo "ERROR: samples directory not given or not found" >&2; exit 2; }

WORK="${CTRLX_TEST_WORK:-$HOME/ctrlx-build-test-$LANG_ID-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$WORK/projects"
RESULTS="$WORK/results.tsv"
printf 'project\tarch\tstatus\tsnap\tbytes\tsha256\telf\tmismatches\tlog\n' > "$RESULTS"

# Build the image once, up front, so that its (long) build is not part of a sample.
"$HERE/ctrlx-build.sh" --build-image || { echo "ERROR: image build failed" >&2; exit 1; }

total=0
warned=0
failed=0
for dir in "$SAMPLES"/*/; do
    name=$(basename "$dir")
    if [ -n "$ONLY" ] && ! [[ ",$ONLY," == *",$name,"* ]]; then continue; fi
    [ -f "$dir/snap/snapcraft.yaml" ] || continue
    cp -a "$dir" "$WORK/projects/$name"
    for arch in "${ARCHES[@]}"; do
        total=$((total + 1))
        out=$("$HERE/ctrlx-build.sh" --project "$WORK/projects/$name" --lang "$LANG_ID" --arch "$arch" 2>&1)
        rc=$?
        log=$(printf '%s\n' "$out" | sed -n 's/^Log: //p' | head -1)
        res=$(printf '%s\n' "$out" | grep '^CTRLX_RESULT ' | tail -1)
        if [ "$rc" -eq 0 ] && [ -n "$res" ]; then
            get() { printf '%s\n' "$res" | tr ' ' '\n' | sed -n "s/^$1=//p"; }
            status=$(get status)
            [ "$status" = ok ] || warned=$((warned + 1))
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$arch" "$status" \
                "$(get snap)" "$(get bytes)" "$(get sha256)" "$(get elf)" "$(get mismatches)" "$log" >> "$RESULTS"
        else
            failed=$((failed + 1))
            printf '%s\t%s\tFAIL(exit %s)\t\t\t\t\t\t%s\n' "$name" "$arch" "$rc" "$log" >> "$RESULTS"
        fi
        printf '%-34s %-6s %s\n' "$name" "$arch" "$(tail -1 "$RESULTS" | cut -f3)"
    done
done

echo
column -t -s "$(printf '\t')" "$RESULTS" | cut -c1-220
printf '\n%d cells: %d ok, %d warn, %d failed. Results: %s\n' \
    "$total" "$((total - warned - failed))" "$warned" "$failed" "$RESULTS"
[ "$failed" -eq 0 ]
