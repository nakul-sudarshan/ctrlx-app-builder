#Author: Nakul Sudarshan (with help from Copilot and Claude) 

#!/usr/bin/env bash
# Maintainer runner for the ctrlX builder: builds, test matrices and records in one command.
#
# Two modes, chosen by the environment variable CTRLX_BUILD_USER:
#   unset (default)   the current account has rootless Docker itself (README Part 2). The project is
#                     copied into a private job folder (~/ctrlx-jobs/<id>), ctrlx-build.sh runs there,
#                     the snap is copied back and verified. No sudo is used.
#   CTRLX_BUILD_USER=<account>
#                     another account owns the rootless Docker daemon (lingering, socket
#                     /run/user/<uid>/docker.sock) and the current account has no Docker: every step
#                     runs through "sudo -u <account>" and the job folder is in that account's home.
#                     The sudo password of the current account is asked once.
#
# Usage:
#   ctrlx-run.sh doctor
#   ctrlx-run.sh image
#   ctrlx-run.sh build [--project DIR] [--lang L] [--arch amd64|arm64|both] [--recipe R] [--keep]
#   ctrlx-run.sh test  <samples-dir> --lang L [--arch amd64|arm64|both] [--only a,b]
#                      [--collect-snaps] [--keep]
#   ctrlx-run.sh test-all <root-dir> [--arch amd64|arm64|both] [--langs a,b] [--collect-snaps]
#   ctrlx-run.sh record-image
#   ctrlx-run.sh check-ownership <project-dir> [--lang L]
#   ctrlx-run.sh image-timing
#
#   doctor  checks sudo, the account, its Docker daemon (rootless), disk space, internet and
#           whether the builder image for the current Dockerfile exists
#   image   builds the builder image (first use downloads; later runs reuse it)
#   build   language/architecture are detected/asked here (flags skip the questions);
#           project default: the folder that contains this ctrlx-build/ folder; the snap
#           and its .sha256 are copied into the project folder, the log into ctrlx-build/logs/
#   test    runs test-samples.sh on a folder of sample projects; results.tsv and logs are
#           copied to ./ctrlx-run-results-<timestamp>/
#   test-all  <root-dir> holds one folder per language (named cpp, dotnet, go, java, node,
#           python), each with one folder per sample project; every language is tested in
#           turn (one password prompt) into ./ctrlx-run-all-<timestamp>/, with summary.tsv
#   record-image  writes ./ctrlx-image-record-<timestamp>/ for the current builder image: image
#           ID (immutable content ID), inspect output, pins and installed packages read from the
#           image, layer history, docker version, input hashes and the build command
#   check-ownership  builds a copy of <project-dir> for both architectures and reports, in
#           ./ctrlx-ownership-check-<timestamp>/ownership-report.txt, who owns the outputs on the
#           host side and inside the container, whether anything in the job folder belongs to
#           another UID, whether the sources were left unchanged, and who owns the delivered snaps
#   image-timing  times a cold image build (--no-cache), the same build again (all cached) and a
#           build after a change to container-build.sh only; records sizes and compares the
#           cold image's package list with a reference record when CTRLX_REFERENCE_RECORD=<dir of a
#           record-image run> is set; writes ./ctrlx-image-timing-<ts>/.
#           Uses the temporary tags ctrlx-builder:timing-cold / timing-script (removed at the end);
#           the regular image tag and the build cache of other images are not touched.
#
# CTRLX_DOCKERFILE=Dockerfile.single (environment variable, any subcommand) selects the generated one-file
# image definition (see make-single-dockerfile.sh); its image tag is ctrlx-builder:single-<hash of that file>.
#
# The job folder is <home of the Docker account>/ctrlx-jobs/<id> (mode 700, created by this script);
# it is removed after a successful run (exact path only) and kept after a failure or with --keep.
#
# Nothing here uses --privileged, the docker group, or a rootful daemon.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DT_USER=${CTRLX_BUILD_USER:-}
if [ -z "$DT_USER" ] || [ "$DT_USER" = "$(id -un)" ]; then
    DT_USER=$(id -un)
    NO_SUDO=1                            # the current account owns the Docker daemon: no sudo
else
    NO_SUDO=${CTRLX_RUN_NO_SUDO:-0}      # second-account mode (CTRLX_RUN_NO_SUDO=1 is a test hook)
fi

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '[ctrlx-run] %s\n' "$*"; }

# ---- account helpers ------------------------------------------------------------
if [ "$NO_SUDO" = 1 ]; then
    DT_HOME=${CTRLX_DT_HOME:-$HOME}
    DT_UID=$(id -u)
else
    getent passwd "$DT_USER" >/dev/null || die "account '$DT_USER' not found"
    DT_HOME=$(getent passwd "$DT_USER" | cut -d: -f6)
    DT_UID=$(id -u "$DT_USER")
fi
XDG=/run/user/$DT_UID
SOCK=${CTRLX_DOCKER_SOCKET:-$XDG/docker.sock}
case "${DOCKER_HOST:-}" in   # same account: follow the socket the Docker client is configured for
    unix://*) [ "$NO_SUDO" = 1 ] && [ -z "${CTRLX_DOCKER_SOCKET:-}" ] && SOCK=${DOCKER_HOST#unix://} ;;
esac
JOBS="$DT_HOME/ctrlx-jobs"

# Run a command as the Docker account with the rootless environment set explicitly
# (a non-interactive shell does not read the user's ~/.bashrc).
as_dt() {
    if [ "$NO_SUDO" = 1 ]; then
        env "$@"
    else
        sudo -u "$DT_USER" -H env \
            "PATH=$DT_HOME/bin:/usr/local/bin:/usr/bin:/bin" \
            "XDG_RUNTIME_DIR=$XDG" "DOCKER_HOST=unix://$SOCK" "CTRLX_DOCKERFILE=${CTRLX_DOCKERFILE:-Dockerfile}" "$@"
    fi
}

KEEPALIVE=""
start_sudo() {
    [ "$NO_SUDO" = 1 ] && return 0
    [ -z "$KEEPALIVE" ] || return 0      # already authenticated in this run
    command -v sudo >/dev/null || die "sudo not found"
    say "sudo password of $(id -un) is needed once to act as '$DT_USER'"
    sudo -v || die "sudo authentication failed"
    # keep the credential alive during long builds
    ( while true; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) &
    KEEPALIVE=$!
}
cleanup_keepalive() { [ -z "$KEEPALIVE" ] || kill "$KEEPALIVE" 2>/dev/null || true; }
trap cleanup_keepalive EXIT

image_tag() {
    if [ "${CTRLX_DOCKERFILE:-Dockerfile}" = Dockerfile.single ]; then
        printf 'ctrlx-builder:single-%s' "$(sha256sum "$HERE/Dockerfile.single" | cut -c1-12)"
    else
        printf 'ctrlx-builder:%s' "$(cat "$HERE/Dockerfile" "$HERE/container-build.sh" | sha256sum | cut -c1-12)"
    fi
}

ID=$(date +%Y%m%d-%H%M%S)-$$
JOB="$JOBS/$ID"
JOB_PATTERN="^${JOBS}/[0-9]{8}-[0-9]{6}-[0-9]+\$"

new_job() {
    as_dt mkdir -p -m 700 "$JOBS" "$JOB"
    as_dt chmod 700 "$JOBS" "$JOB"
}

stage_builder() {
    as_dt mkdir -p "$JOB/ctrlx-build"
    # result folders of earlier runs (they may hold collected snaps) are not part of the builder
    tar -C "$HERE" --exclude=./logs --exclude='./ctrlx-run-results-*' --exclude='./ctrlx-run-all-*' \
        -cf - . | as_dt tar -C "$JOB/ctrlx-build" -xf -
}

remove_job() {
    [[ "$JOB" =~ $JOB_PATTERN ]] || die "refusing to remove unexpected path: $JOB"
    as_dt rm -rf -- "$JOB"
}

# ---- doctor ---------------------------------------------------------------------
cmd_doctor() {
    local ok=1
    start_sudo
    check() { # check "label" command...
        local label=$1
        shift
        if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$label"; else printf '  FAIL  %s\n' "$label"; ok=0; fi
    }
    say "checking account '$DT_USER' (uid $DT_UID), home $DT_HOME"
    check "account home exists" as_dt test -d "$DT_HOME"
    check "rootless Docker socket $SOCK" as_dt test -S "$SOCK"
    check "docker client runs" as_dt docker version --format '{{.Client.Version}}'
    check "docker daemon answers" as_dt docker info --format '{{.ServerVersion}}'
    if as_dt docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
        printf '  ok    daemon is rootless\n'
    else
        printf '  FAIL  daemon is not rootless\n'; ok=0
    fi
    local free
    free=$(as_dt df --output=avail -BG "$DT_HOME" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
    if [ -n "$free" ] && [ "$free" -ge 20 ]; then printf '  ok    free disk space: %s GB\n' "$free"; else printf '  FAIL  free disk space: %s GB (20 GB wanted)\n' "${free:-?}"; ok=0; fi
    check "internet from the account (api.snapcraft.io)" as_dt curl -sS -m 15 -o /dev/null https://api.snapcraft.io
    if as_dt docker image inspect "$(image_tag)" >/dev/null 2>&1; then
        printf '  ok    builder image present: %s\n' "$(image_tag)"
    else
        printf '  note  builder image %s not built yet (run: %s image)\n' "$(image_tag)" "$0"
    fi
    [ "$ok" = 1 ] && say "all checks passed" || die "some checks failed"
}

# ---- image ------------------------------------------------------------------------
cmd_image() {
    start_sudo
    new_job
    stage_builder
    say "building the builder image (first use downloads several hundred MB)"
    as_dt bash "$JOB/ctrlx-build/ctrlx-build.sh" --build-image
    remove_job
}

# ---- build ------------------------------------------------------------------------
cmd_build() {
    local project="" lang="" arch="" recipe=auto keep=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --project) project=$(cd "${2:-}" && pwd) || die "project folder not found"; shift 2 ;;
            --lang) lang=${2:-}; shift 2 ;;
            --arch) arch=${2:-}; shift 2 ;;
            --recipe) recipe=${2:-}; shift 2 ;;
            --keep) keep=1; shift ;;
            *) die "unknown argument: $1" ;;
        esac
    done
    [ -n "$project" ] || project=$(dirname "$HERE")
    [ -f "$project/snap/snapcraft.yaml" ] || die "$project/snap/snapcraft.yaml not found"

    # Language and architecture are resolved here, in the terminal of the normal account
    # (detection and questions need no Docker).
    local args=(--project "$project")
    [ -z "$lang" ] || args+=(--lang "$lang")
    if [ "$arch" = both ]; then args+=(--arch amd64); else [ -z "$arch" ] || args+=(--arch "$arch"); fi
    local resolved
    resolved=$("$HERE/ctrlx-build.sh" "${args[@]}" --resolve-only | grep '^RESOLVED ' || true)
    [ -n "$resolved" ] || die "language/architecture could not be determined (see the messages above)"
    lang=$(sed -n 's/.*lang=\([^ ]*\).*/\1/p' <<<"$resolved")
    [ "$arch" = both ] || arch=$(sed -n 's/.*arch=\([^ ]*\).*/\1/p' <<<"$resolved")
    say "project $project: lang=$lang arch=$arch recipe=$recipe"

    start_sudo
    new_job
    stage_builder
    as_dt mkdir -p "$JOB/project"
    say "staging the project (job $JOB)"
    tar -C "$project" --anchored \
        --exclude=./.git --exclude=./ctrlx-build --exclude='./*.snap' --exclude='./*.snap.sha256' \
        --exclude=./parts --exclude=./prime --exclude=./stage --exclude=./overlay --exclude=./.craft \
        -cf - . | as_dt tar -C "$JOB/project" -xf -

    local arches=("$arch") a rc=0
    [ "$arch" != both ] || arches=(amd64 arm64)
    mkdir -p "$HERE/logs"
    for a in "${arches[@]}"; do
        say "building $lang for $a (the image is built first if it does not exist)"
        local runlog="$HERE/logs/run-$(basename "$project")-$lang-$a-$ID.log"
        set +e
        as_dt bash "$JOB/ctrlx-build/ctrlx-build.sh" --project "$JOB/project" --lang "$lang" \
            --arch "$a" --recipe "$recipe" 2>&1 | tee "$runlog"
        local r=${PIPESTATUS[0]}
        set -e
        if [ "$r" -ne 0 ]; then rc=$r; say "build for $a failed (exit $r); log: $runlog"; break; fi
        # copy the snap and its checksum back into the project folder, then verify
        if ! as_dt bash -c 'cd "$1" && tar -cf - ./*_"$2".snap ./*_"$2".snap.sha256' _ "$JOB/project" "$a" \
                | tar -C "$project" -xf -; then
            rc=1; say "no snap for $a found in the job folder"; break
        fi
        if ( cd "$project" && sha256sum --check --quiet ./*_"${a}".snap.sha256 ); then
            say "snap for $a copied to $project and checksum verified"
        else
            rc=1; say "checksum verification failed for $a"; break
        fi
    done

    # builder logs of this job
    as_dt tar -C "$JOB/ctrlx-build" -cf - logs 2>/dev/null | tar -C "$HERE" -xf - 2>/dev/null || true

    if [ "$rc" -eq 0 ] && [ "$keep" = 0 ]; then
        remove_job
    else
        say "job folder kept for inspection: $JOB (account $DT_USER)"
    fi
    return "$rc"
}

# ---- test -------------------------------------------------------------------------
cmd_test() {
    local samples="" lang="" arch=both only="" collect=0 keep=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --lang) lang=${2:-}; shift 2 ;;
            --arch) arch=${2:-}; shift 2 ;;
            --only) only=${2:-}; shift 2 ;;
            --collect-snaps) collect=1; shift ;;
            --keep) keep=1; shift ;;
            -*) die "unknown argument: $1" ;;
            *) samples=$(cd "$1" && pwd) || die "samples folder not found"; shift ;;
        esac
    done
    [ -n "$samples" ] || die "samples folder missing"
    [ -n "$lang" ] || die "--lang is required for test"

    start_sudo
    new_job
    stage_builder
    as_dt mkdir -p "$JOB/samples" "$JOB/work"
    say "staging samples from $samples"
    tar -C "$samples" -cf - . | as_dt tar -C "$JOB/samples" -xf -

    local targs=("$JOB/samples" --lang "$lang" --arch "$arch")
    [ -z "$only" ] || targs+=(--only "$only")
    local out="$PWD/ctrlx-run-results-$ID"
    mkdir -p "$out"
    local rc=0
    set +e
    as_dt "CTRLX_TEST_WORK=$JOB/work" bash "$JOB/ctrlx-build/test-samples.sh" "${targs[@]}" 2>&1 | tee "$out/test-output.log"
    rc=${PIPESTATUS[0]}
    set -e

    as_dt cat "$JOB/work/results.tsv" > "$out/results.tsv" 2>/dev/null || true
    as_dt tar -C "$JOB/ctrlx-build" -cf - logs 2>/dev/null | tar -C "$out" -xf - 2>/dev/null || true
    if [ "$collect" = 1 ]; then
        mkdir -p "$out/snaps"
        as_dt bash -c 'cd "$1" && find projects -name "*.snap" -o -name "*.snap.sha256"' _ "$JOB/work" \
            | while IFS= read -r f; do
                rel=${f#projects/}
                mkdir -p "$out/snaps/$(dirname "$rel")"
                as_dt cat "$JOB/work/$f" > "$out/snaps/$rel"
              done
    fi
    say "results in $out"
    if [ "$rc" -eq 0 ] && [ "$keep" = 0 ]; then remove_job; else say "job folder kept: $JOB (account $DT_USER)"; fi
    return "$rc"
}

# ---- test-all ---------------------------------------------------------------------
cmd_test_all() {
    local root="" arch=both langs="cpp,dotnet,go,java,node,python" extra=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --arch) arch=${2:-}; shift 2 ;;
            --langs) langs=${2:-}; shift 2 ;;
            --collect-snaps) extra+=(--collect-snaps); shift ;;
            -*) die "unknown argument: $1" ;;
            *) root=$(cd "$1" && pwd) || die "root folder not found"; shift ;;
        esac
    done
    [ -n "$root" ] || die "root folder missing (one sub-folder per language)"
    local all="$PWD/ctrlx-run-all-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$all"
    start_sudo
    printf 'lang\tok\twarn\tfail\tcells\tresults\n' > "$all/summary.tsv"
    local l rc=0 base="$PWD" n=0
    cd "$all"
    for l in ${langs//,/ }; do
        [ -d "$root/$l" ] || { say "skipping $l: no folder $root/$l"; continue; }
        n=$((n+1))
        [ "$n" -eq 1 ] || sleep 1                     # distinct job id per language
        ID=$(date +%Y%m%d-%H%M%S)-$$
        JOB="$JOBS/$ID"
        say "===== language: $l ====="
        if ! cmd_test "$root/$l" --lang "$l" --arch "$arch" "${extra[@]}"; then rc=1; fi
        local r="ctrlx-run-results-$ID"
        awk -F'\t' -v l="$l" -v r="$r" 'NR>1{c++; if($3=="ok")o++; else if($3=="warn")w++; else f++}
            END{printf "%s\t%d\t%d\t%d\t%d\t%s\n", l, o, w, f, c, r}' "$r/results.tsv" >> summary.tsv 2>/dev/null \
            || printf '%s\t?\t?\t?\t?\t%s (no results.tsv)\n' "$l" "$r" >> summary.tsv
    done
    cd "$base"
    say "summary ($all/summary.tsv):"
    column -t -s$'\t' "$all/summary.tsv"
    return "$rc"
}

# ---- record-image -----------------------------------------------------------------
# Records what identifies the builder image. A locally built image has an ID (content digest of
# its configuration) but no registry digest (RepoDigests stays empty until it is pushed).
cmd_record_image() {
    local img rec
    img=$(image_tag)
    start_sudo
    as_dt docker image inspect "$img" >/dev/null 2>&1 || die "image $img not found (run: $0 image)"
    rec="./ctrlx-image-record-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$rec"
    as_dt docker image inspect "$img" > "$rec/image-inspect.json"
    as_dt docker image inspect "$img" --format \
        'tag={{index .RepoTags 0}}
id={{.Id}}
created={{.Created}}
os_arch={{.Os}}/{{.Architecture}}
size_bytes={{.Size}}
repo_digests={{.RepoDigests}}
labels={{json .Config.Labels}}' > "$rec/image-id.txt"
    for f in pins.txt installed-packages.txt; do
        as_dt docker run --rm --network none --entrypoint /bin/cat "$img" "/opt/ctrlx-builder/$f" > "$rec/$f"
    done
    as_dt docker history --no-trunc --format '{{.CreatedBy}}\t{{.Size}}' "$img" > "$rec/history.txt"
    { as_dt docker version --format 'client={{.Client.Version}} server={{.Server.Version}}'
      as_dt docker info --format 'security={{json .SecurityOptions}} storage={{.Driver}} os={{.OperatingSystem}} kernel={{.KernelVersion}}'
    } > "$rec/docker-environment.txt" 2>&1 || true
    ( cd "$HERE" && sha256sum Dockerfile container-build.sh ) > "$rec/build-inputs.sha256"
    {
        printf 'Image:   %s\n' "$img"
        printf 'Inputs:  Dockerfile and container-build.sh (hashes in build-inputs.sha256); the tag is the first 12 hex of\n'
        printf '         sha256(Dockerfile followed by container-build.sh). Every download in the Dockerfile is pinned and verified;\n'
        printf '         apt packages are not pinned and are recorded in installed-packages.txt, so a rebuild gives an equivalent,\n'
        printf '         not a bit-identical, image (a new image ID).\n\n'
        printf 'Build (as the rootless account; the context needs only these two files):\n'
        printf '  mkdir -p /tmp/ctrlx-builder-ctx && cp Dockerfile container-build.sh /tmp/ctrlx-builder-ctx/\n'
        printf '  docker build --tag %s --file /tmp/ctrlx-builder-ctx/Dockerfile /tmp/ctrlx-builder-ctx\n\n' "$img"
        printf 'Same through the scripts:  ./ctrlx-run.sh image   (stages ctrlx-build/ and runs ctrlx-build.sh --build-image)\n'
    } > "$rec/BUILD-COMMAND.txt"
    [ "$(printf '%s' "$img")" = "ctrlx-builder:$(cat "$HERE/Dockerfile" "$HERE/container-build.sh" | sha256sum | cut -c1-12)" ] \
        || die "tag does not match the input hashes"
    say "record written to $rec"
    cat "$rec/image-id.txt" | cut -c1-200
}

# ---- check-ownership --------------------------------------------------------------
# Rootless Docker maps the container's root to the Docker account, so files written by the
# build must belong to that account on the host (no root-owned files, no sub-UIDs), the
# project sources must stay unchanged, and the snaps delivered to the normal account must be
# owned by it.
cmd_check_ownership() {
    local src="" extra=() out rc=0 fails=0
    [ $# -ge 1 ] || die "usage: $0 check-ownership <project-dir> [--lang L]"
    src=$(cd "$1" && pwd) || die "project folder not found"; shift
    extra=("$@")
    [ -f "$src/snap/snapcraft.yaml" ] || die "$src/snap/snapcraft.yaml not found"
    out="$PWD/ctrlx-ownership-check-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$out/project"
    tar -C "$src" --anchored --exclude=./.git --exclude=./ctrlx-build --exclude='./*.snap' \
        --exclude='./*.snap.sha256' -cf - . | tar -C "$out/project" -xf -
    ( cd "$out/project" && find . -type f | sort | xargs sha256sum ) > "$out/source-before.sha256"

    cmd_build --project "$out/project" --arch both --keep "${extra[@]}" || rc=$?
    [ "$rc" -eq 0 ] || die "build failed (exit $rc); job folder kept: $JOB"

    local rep="$out/ownership-report.txt" img
    img=$(image_tag)
    verdict() { # verdict "label" 0|1
        if [ "$2" = 0 ]; then printf 'PASS  %s\n' "$1" >> "$rep"; else printf 'FAIL  %s\n' "$1" >> "$rep"; fails=$((fails+1)); fi
    }
    {
        printf 'Ownership check, %s\nImage: %s\nDocker account: %s (uid %s, gid %s); normal account: %s (uid %s, gid %s)\n\n' \
            "$(date -Is)" "$img" "$DT_USER" "$DT_UID" "$(id -g "$DT_USER" 2>/dev/null || id -g)" "$(id -un)" "$(id -u)" "$(id -g)"
        printf '== job folder (Docker account side): numeric owner:group mode type path (snaps)\n'
        as_dt find "$JOB/project" -maxdepth 1 -name '*.snap*' -printf '%U:%G %m %y %p\n'
        printf '\n== job folder: entries not owned by uid %s or not in its group (first 20)\n' "$DT_UID"
        as_dt find "$JOB" \( ! -uid "$DT_UID" -o ! -gid "$(as_dt id -g)" \) -printf '%U:%G %p\n' | head -20
    } > "$rep"
    local foreign
    foreign=$(as_dt find "$JOB" \( ! -uid "$DT_UID" -o ! -gid "$(as_dt id -g)" \) | wc -l)
    printf 'count: %s\n' "$foreign" >> "$rep"
    verdict "no file in the job folder belongs to another UID/GID (found: $foreign)" "$([ "$foreign" = 0 ] && echo 0 || echo 1)"

    local bad
    bad=$(as_dt find "$JOB/project" -maxdepth 1 -name '*.snap*' ! -uid "$DT_UID" | wc -l)
    verdict "snaps and checksum files in the job folder belong to $DT_USER (not owned: $bad)" "$([ "$bad" = 0 ] && echo 0 || echo 1)"

    printf '\n== container view of the same files (read-only mount): uid:gid mode path\n' >> "$rep"
    local cview
    cview=$(as_dt docker run --rm --network none --entrypoint /bin/bash --volume "$JOB/project:/p:ro" "$img" \
        -c 'echo "container user: $(id -u):$(id -g)"; stat -c "%u:%g %a %n" /p/*.snap /p/*.snap.sha256' 2>&1) || true
    printf '%s\n' "$cview" >> "$rep"
    verdict "inside the container the files appear as root (0:0) and the user is root" \
        "$(grep -q '^container user: 0:0' <<<"$cview" && ! grep -qE '^[1-9][0-9]*:' <<<"$(grep -v '^container' <<<"$cview")" && echo 0 || echo 1)"

    as_dt bash -c 'cd "$1/project" && find . -type f ! -name "*.snap" ! -name "*.snap.sha256" | sort | xargs sha256sum' _ "$JOB" \
        > "$out/source-after.sha256"
    printf '\n== project sources before/after the builds\n' >> "$rep"
    if diff -q "$out/source-before.sha256" "$out/source-after.sha256" >/dev/null; then
        printf 'identical (%s files)\n' "$(wc -l < "$out/source-before.sha256")" >> "$rep"; verdict "project sources unchanged by the builds" 0
    else
        diff "$out/source-before.sha256" "$out/source-after.sha256" >> "$rep" || true; verdict "project sources unchanged by the builds" 1
    fi

    printf '\n== delivered to the normal account: owner:group uid:gid mode path\n' >> "$rep"
    stat -c '%U:%G %u:%g %a %n' "$out"/project/*.snap "$out"/project/*.snap.sha256 >> "$rep"
    local wrong
    wrong=$(find "$out/project" -maxdepth 1 -name '*.snap*' \( ! -uid "$(id -u)" -o ! -gid "$(id -g)" \) | wc -l)
    verdict "delivered snaps belong to $(id -un) (not owned: $wrong)" "$([ "$wrong" = 0 ] && echo 0 || echo 1)"

    remove_job
    printf '\n%s\n' "$([ "$fails" = 0 ] && echo 'RESULT: all ownership checks passed' || echo "RESULT: $fails check(s) FAILED")" >> "$rep"
    cat "$rep"
    say "report: $rep"
    [ "$fails" = 0 ]
}

# ---- image-timing --------------------------------------------------------------------
cmd_image_timing() {
    local rep ref now
    rep="$PWD/ctrlx-image-timing-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$rep"
    start_sudo
    new_job
    stage_builder
    as_dt bash -c 'mkdir -p "$1/ctx" && cp "$1/ctrlx-build/Dockerfile" "$1/ctrlx-build/container-build.sh" "$1/ctx/"' _ "$JOB"
    local ctx="$JOB/ctx"
    now() { date +%s.%N; }
    step() { # step <label> <logfile> <docker build args...>: prints the duration
        local label=$1 log=$2 t0 t1
        shift 2
        say "$label"
        t0=$(now)
        as_dt docker build --progress=plain "$@" "$ctx" > "$rep/$log" 2>&1 || { say "build failed, see $rep/$log"; return 1; }
        t1=$(now)
        awk -v a="$t0" -v b="$t1" -v l="$label" -v f="$log" \
            'BEGIN{printf "%-44s %8.1f s   (%s)\n", l, b-a, f}' | tee -a "$rep/timing.txt"
    }
    {
        printf 'Image timing, %s\nHost: %s, %s CPUs, %s\nFree disk before: %s\nDocker: ' \
            "$(date -Is)" "$(uname -sr)" "$(nproc)" "$(awk '/MemTotal/{printf "%.0f GiB RAM", $2/1048576}' /proc/meminfo)" \
            "$(as_dt df -h --output=avail "$DT_HOME" | tail -1 | tr -d ' ')"
        as_dt docker version --format 'client {{.Client.Version}} server {{.Server.Version}}'
        as_dt docker system df
        printf '\n'
    } > "$rep/timing.txt" 2>&1
    local rc=0
    step "1 cold build (--no-cache)" cold-build.log --no-cache --tag ctrlx-builder:timing-cold --file "$ctx/Dockerfile" || rc=1
    if [ "$rc" = 0 ]; then
        step "2 same build again (cache)" warm-same.log --tag ctrlx-builder:timing-cold --file "$ctx/Dockerfile" || rc=1
    fi
    if [ "$rc" = 0 ]; then
        as_dt bash -c 'printf "\n# timing touch\n" >> "$1/ctx/container-build.sh"' _ "$JOB"
        step "3 container-build.sh changed (cache)" warm-script.log --tag ctrlx-builder:timing-script --file "$ctx/Dockerfile" || rc=1
    fi
    if [ "$rc" = 0 ]; then
        {
            printf '\ncache use (lines "CACHED" / lines "DONE" in the plain progress output)\n'
            for f in cold-build warm-same warm-script; do
                printf '  %-12s CACHED=%s DONE=%s\n' "$f" "$(grep -c ' CACHED$' "$rep/$f.log" || true)" "$(grep -cE '^#[0-9]+ DONE' "$rep/$f.log" || true)"
            done
            printf '\nimage size (bytes) and ID\n'
            as_dt docker image inspect ctrlx-builder:timing-cold --format '  timing-cold   {{.Size}}  {{.Id}}'
            as_dt docker image inspect "$(image_tag)" --format '  recorded  {{.Size}}  {{.Id}}  ({{index .RepoTags 0}})' 2>/dev/null || true
            as_dt docker system df
        } >> "$rep/timing.txt" 2>&1
        for f in pins.txt installed-packages.txt; do
            as_dt docker run --rm --network none --entrypoint /bin/cat ctrlx-builder:timing-cold "/opt/ctrlx-builder/$f" > "$rep/cold-$f"
        done
        ref=${CTRLX_REFERENCE_RECORD:-}
        if [ -n "$ref" ] && [ -d "$ref" ]; then
            {
                printf '\ncomparison of the cold image with the reference record (%s)\n' "$ref"
                for f in pins.txt installed-packages.txt; do
                    if diff -q "$ref/$f" "$rep/cold-$f" >/dev/null; then printf '  %-22s identical\n' "$f"
                    else printf '  %-22s DIFFERS\n' "$f"; diff "$ref/$f" "$rep/cold-$f" | head -40; fi
                done
            } >> "$rep/timing.txt"
        fi
    fi
    # temporary tags only, by exact name; the regular image and its layers stay
    as_dt docker rmi ctrlx-builder:timing-script ctrlx-builder:timing-cold >> "$rep/timing.txt" 2>&1 || true
    as_dt docker system df >> "$rep/timing.txt" 2>&1 || true
    remove_job
    cat "$rep/timing.txt"
    say "report: $rep/timing.txt"
    return "$rc"
}

# ---- dispatch ---------------------------------------------------------------------
sub=${1:-}
[ $# -eq 0 ] || shift
case "$sub" in
    doctor) cmd_doctor ;;
    image)  cmd_image ;;
    build)  cmd_build "$@" ;;
    test)   cmd_test "$@" ;;
    test-all) cmd_test_all "$@" ;;
    record-image) cmd_record_image ;;
    check-ownership) cmd_check_ownership "$@" ;;
    image-timing) cmd_image_timing ;;
    -h|--help|"") sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$sub' (doctor, image, build, test, test-all, record-image, check-ownership, image-timing)" ;;
esac
