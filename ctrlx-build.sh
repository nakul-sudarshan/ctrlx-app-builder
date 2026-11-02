#Author: Nakul Sudarshan (with help from Copilot and Claude) 

#!/usr/bin/env bash
# Build a ctrlX app snap from the project folder that contains this ctrlx-build/ folder.
#
#   <project>/
#     snap/snapcraft.yaml      supplied by the developer
#     <sources, nuget.config>  supplied by the developer
#     ctrlx-build/             this folder (Dockerfile + scripts)
#
# Usage: ctrlx-build/ctrlx-build.sh [--lang cpp|dotnet|go|java|node|python] [--arch amd64|arm64]
#                                   [--project DIR] [--recipe auto|shared|project]
#                                   [--build-image] [--detect-only]
#
# Without --lang/--arch the script detects the language from the project files and
# asks for confirmation, then asks for the architecture. The builder image is built
# on first use (downloads, needs internet) and reused afterwards. The snap, its
# .sha256 file and a log end up in the project folder (log: ctrlx-build/logs/).
#
# Requires rootless Docker, run as the invoking user (no sudo, no docker group).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(dirname "$HERE")
LANG_ID=""
ARCH=""
BUILD_IMAGE_ONLY=0
DETECT_ONLY=0
RESOLVE_ONLY=0
RECIPE=auto

KNOWN_LANGS=(cpp dotnet go java node python)
ENABLED_LANGS=(cpp dotnet go java node python)

die() {
    local code=$1
    shift
    printf 'ERROR: %s\n' "$*" >&2
    exit "$code"
}

in_list() {
    local needle=$1
    shift
    local x
    for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --lang) LANG_ID=${2:-}; shift 2 ;;
        --arch) ARCH=${2:-}; shift 2 ;;
        --project) PROJECT=$(cd "${2:-}" && pwd) || die 2 "project folder not found"; shift 2 ;;
        --recipe) RECIPE=${2:-}; shift 2 ;;
        --build-image) BUILD_IMAGE_ONLY=1; shift ;;
        --detect-only) DETECT_ONLY=1; shift ;;
        --resolve-only) RESOLVE_ONLY=1; shift ;;
        -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die 2 "unknown argument: $1 (see --help)" ;;
    esac
done

interactive=0
[ -t 0 ] && interactive=1

ask_choice() {   # ask_choice "prompt" option...  -> prints the chosen option
    local prompt=$1
    shift
    local opts=("$@") i reply
    {
        printf '%s\n' "$prompt"
        for i in "${!opts[@]}"; do printf '  %d) %s\n' $((i + 1)) "${opts[$i]}"; done
    } >&2
    while true; do
        read -r -p "Choice [1-${#opts[@]}]: " reply
        if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#opts[@]}" ]; then
            printf '%s\n' "${opts[$((reply - 1))]}"
            return 0
        fi
        # also accept the option text itself
        if in_list "$reply" "${opts[@]}"; then printf '%s\n' "$reply"; return 0; fi
    done
}

# ---- language -----------------------------------------------------------------
detect_languages() {
    local found=()
    compgen -G "$PROJECT/*.csproj" >/dev/null && found+=(dotnet)
    [ -f "$PROJECT/CMakeLists.txt" ] && found+=(cpp)
    [ -f "$PROJECT/go.mod" ] && found+=(go)
    [ -f "$PROJECT/package.json" ] && found+=(node)
    { compgen -G "$PROJECT/settings.gradle*" >/dev/null || compgen -G "$PROJECT/build.gradle*" >/dev/null; } && found+=(java)
    { [ -f "$PROJECT/pyproject.toml" ] || [ -f "$PROJECT/setup.py" ] || [ -f "$PROJECT/requirements.txt" ]; } && found+=(python)
    printf '%s\n' "${found[@]}"
}

if [ "$BUILD_IMAGE_ONLY" = 0 ]; then   # language and architecture are not needed to build the image

[ -f "$PROJECT/snap/snapcraft.yaml" ] \
    || die 3 "$PROJECT/snap/snapcraft.yaml not found; run this from a ctrlx-build/ folder inside the project, or use --project"

if [ -z "$LANG_ID" ]; then
    mapfile -t detected < <(detect_languages)
    if [ "${#detected[@]}" -eq 1 ]; then
        LANG_ID=${detected[0]}
        if [ "$interactive" = 1 ] && [ "$DETECT_ONLY" = 0 ]; then
            read -r -p "Detected language: $LANG_ID. Use it? [Y/n] " reply
            case "${reply:-y}" in
                n|N) LANG_ID=$(ask_choice "Select the language:" "${KNOWN_LANGS[@]}") ;;
            esac
        else
            printf 'Detected language: %s\n' "$LANG_ID"
        fi
    elif [ "$DETECT_ONLY" = 1 ]; then
        printf 'Detected languages: %s\n' "${detected[*]:-none}"
        exit 0
    elif [ "$interactive" = 1 ]; then
        if [ "${#detected[@]}" -gt 1 ]; then
            LANG_ID=$(ask_choice "Several languages detected, select one:" "${detected[@]}")
        else
            LANG_ID=$(ask_choice "Language not detected, select it:" "${KNOWN_LANGS[@]}")
        fi
    else
        die 2 "language not determined (detected: ${detected[*]:-none}); pass --lang"
    fi
fi
in_list "$LANG_ID" "${KNOWN_LANGS[@]}" || die 2 "unknown language '$LANG_ID' (known: ${KNOWN_LANGS[*]})"
if [ "$DETECT_ONLY" = 1 ]; then printf 'Language: %s\n' "$LANG_ID"; exit 0; fi
in_list "$LANG_ID" "${ENABLED_LANGS[@]}" \
    || die 2 "language '$LANG_ID': recipe not enabled yet (currently enabled: ${ENABLED_LANGS[*]})"

# ---- architecture -------------------------------------------------------------
if [ -z "$ARCH" ]; then
    if [ "$interactive" = 1 ]; then
        ARCH=$(ask_choice "Target CPU architecture:" amd64 arm64)
    else
        die 2 "architecture not given; pass --arch amd64|arm64"
    fi
fi
in_list "$ARCH" amd64 arm64 || die 2 "unknown architecture '$ARCH' (amd64 or arm64)"

fi   # BUILD_IMAGE_ONLY = 0

# Used by ctrlx-run.sh: language and architecture are resolved in the caller's terminal.
if [ "$RESOLVE_ONLY" = 1 ]; then printf 'RESOLVED lang=%s arch=%s\n' "$LANG_ID" "$ARCH"; exit 0; fi

# ---- Docker -------------------------------------------------------------------
command -v docker >/dev/null || die 2 "docker not found"
docker info >/dev/null 2>&1 || die 2 "cannot talk to the Docker daemon (rootless Docker running for this user?)"
if ! docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    [ "${CTRLX_ALLOW_ROOTFUL:-0}" = 1 ] \
        || die 2 "rootless Docker is required (output ownership and isolation); set CTRLX_ALLOW_ROOTFUL=1 to override"
fi

# The tag follows the content of the image definition, so edits trigger a rebuild.
# CTRLX_DOCKERFILE=Dockerfile.single selects the generated one-file definition (script embedded);
# its tag is the hash of that file alone and carries the prefix single-.
DOCKERFILE=${CTRLX_DOCKERFILE:-Dockerfile}
case "$DOCKERFILE" in
    Dockerfile)        tag=$(cat "$HERE/Dockerfile" "$HERE/container-build.sh" | sha256sum | cut -c1-12); IMAGE="ctrlx-builder:$tag" ;;
    Dockerfile.single) [ -f "$HERE/Dockerfile.single" ] || die 2 "Dockerfile.single not found; run make-single-dockerfile.sh"
                       tag=$(sha256sum "$HERE/Dockerfile.single" | cut -c1-12); IMAGE="ctrlx-builder:single-$tag" ;;
    *) die 2 "CTRLX_DOCKERFILE must be Dockerfile or Dockerfile.single" ;;
esac
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    printf 'Builder image %s not found; building it (first use downloads the SDK and tools).\n' "$IMAGE"
    docker build --tag "$IMAGE" --file "$HERE/$DOCKERFILE" "$HERE"
fi
[ "$BUILD_IMAGE_ONLY" = 1 ] && { printf 'Image ready: %s\n' "$IMAGE"; exit 0; }

# ---- build --------------------------------------------------------------------
NAME=$(basename "$PROJECT")
mkdir -p "$HERE/logs"
LOG="$HERE/logs/${NAME}-${LANG_ID}-${ARCH}-$(date +%Y%m%d-%H%M%S).log"
printf 'Building %s (%s, %s) with %s\nLog: %s\n' "$NAME" "$LANG_ID" "$ARCH" "$IMAGE" "$LOG"

set +e
docker run --rm \
    --volume "$PROJECT:/project:ro" \
    --volume "$PROJECT:/out" \
    "$IMAGE" --lang "$LANG_ID" --arch "$ARCH" --name "$NAME" --recipe "$RECIPE" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -ne 0 ]; then
    printf 'Build failed (exit %s). Log: %s\n' "$rc" "$LOG" >&2
    exit "$rc"
fi
grep '^CTRLX_RESULT ' "$LOG" | tail -1
