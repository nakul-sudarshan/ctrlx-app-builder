#Author: Nakul Sudarshan (with help from Copilot and Claude) 

#!/usr/bin/env bash
# Runs INSIDE the builder image (entrypoint). Not meant to be started by hand.
#
# Contract (set up by ctrlx-build.sh):
#   /project  the user's project folder, mounted read-only
#   /out      the same folder, writable; only the snap, its .sha256 are written here
#   /sdk      the unmodified ctrlX SDK (sample project directories removed)
#
# The project is copied to the position the SDK samples occupy
# (/sdk/<samples-group>/<name>), so that relative references such as
# ../../nuget, ../../scripts or ../build-node-app.sh resolve unchanged.
#
# Recipes: "project" runs the project's own build-snap-<arch>.sh, "shared" the
# built-in per-language recipe, "auto" (default) takes the project script if present.
#
# Exit codes: 0 ok, 2 usage/unsupported language, 3 unsupported project,
#             4 build step failed, 5 no or wrong snap produced.
set -euo pipefail

SDK=${CTRLX_SDK:-/sdk}
PROJECT=${CTRLX_PROJECT:-/project}
OUT=${CTRLX_OUT:-/out}

LANG_ID=""
ARCH=""
NAME=""
RECIPE=auto
DRY_RUN=0

die() {
    local code=$1
    shift
    printf 'ERROR: %s\n' "$*" >&2
    exit "$code"
}

log() { printf '[ctrlx-build] %s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --lang) LANG_ID=${2:-}; shift 2 ;;
        --arch) ARCH=${2:-}; shift 2 ;;
        --name) NAME=${2:-}; shift 2 ;;
        --recipe) RECIPE=${2:-}; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) die 2 "unknown argument: $1" ;;
    esac
done

[ -n "$LANG_ID" ] && [ -n "$ARCH" ] && [ -n "$NAME" ] \
    || die 2 "usage: ctrlx-container-build --lang <lang> --arch <amd64|arm64> --name <project> [--recipe auto|shared|project] [--dry-run]"

# Languages with an enabled recipe (all six).
case "$LANG_ID" in
    dotnet) GROUP=samples-net ;;
    cpp)    GROUP=samples-cpp ;;
    go)     GROUP=samples-go ;;
    node)   GROUP=samples-node ;;
    python) GROUP=samples-python ;;
    java)   GROUP=samples-java ;;
    *) die 2 "unknown language '$LANG_ID'" ;;
esac

case "$ARCH" in
    amd64) RID=linux-x64 ;;
    arm64) RID=linux-arm64 ;;
    *) die 2 "unknown architecture '$ARCH' (amd64 or arm64)" ;;
esac

NAME=${NAME//[^A-Za-z0-9._-]/_}

# ---- validate the project -------------------------------------------------
[ -d "$PROJECT" ] || die 2 "project folder $PROJECT is not mounted"
yaml="$PROJECT/snap/snapcraft.yaml"
[ -f "$yaml" ] || die 3 "snap/snapcraft.yaml not found in the project folder"
grep -Eq '^base:[[:space:]]*core24([[:space:]]|#|$)' "$yaml" \
    || die 3 "only 'base: core24' projects are supported (see snap/snapcraft.yaml)"

# ---- copy the project to its SDK-relative position ------------------------
WORK="$SDK/$GROUP/$NAME"
[ ! -e "$WORK" ] || die 2 "$WORK already exists in the image"
mkdir -p "$WORK"

# Build outputs and tool folders are left behind, so every build starts clean.
excludes=(--exclude=./ctrlx-build --exclude=./.git --exclude=./.craft
          --exclude=./parts --exclude=./prime --exclude=./stage --exclude=./overlay
          --exclude='./*.snap' --exclude='./*.snap.sha256')
case "$LANG_ID" in
    dotnet) excludes+=(--exclude=./.vs --exclude=./bin --exclude=./obj --exclude=./publish) ;;
    cpp)    excludes+=(--exclude=./build --exclude=./generated) ;;
    node)   excludes+=(--exclude=./node_modules --exclude=./dist --exclude='./*.tgz') ;;
    python) excludes+=(--exclude=./venv --exclude=./.venv --exclude=./build --exclude=./dist --exclude='./*.egg-info') ;;
    java)   excludes+=(--exclude=./java --exclude=./.gradle --exclude=./.kotlin --exclude=./build --exclude=./app/build) ;;
esac
tar -C "$PROJECT" --anchored "${excludes[@]}" -cf - . | tar -C "$WORK" -xf -
[ "$LANG_ID" != python ] || find "$WORK" -name __pycache__ -type d -prune -exec rm -rf {} +
# Files in wrapper/ end up as the app commands. Sources taken from a ZIP archive carry no
# execute bits (git keeps them), and snap packing then fails late with "should be executable".
if [ -d "$WORK/wrapper" ]; then
    mapfile -t noexec < <(find "$WORK/wrapper" -type f ! -perm -u+x)
    if [ "${#noexec[@]}" -gt 0 ]; then
        printf '[ctrlx-build] WARNING: no execute bit on %s; packing is likely to fail ("should be executable"). Sources from a ZIP lose file modes: use the git checkout or set the bit in the project folder\n' \
            "$(printf '%s ' "${noexec[@]#"$WORK"/}")"
    fi
fi
# The Snapcraft Gradle plugin starts ./gradlew directly; the SDK release archive stores it
# without the execute bit. Only the container copy of the project is changed.
if [ "$LANG_ID" = java ] && [ -f "$WORK/gradlew" ] && [ ! -x "$WORK/gradlew" ]; then
    chmod +x "$WORK/gradlew"
    log "container copy: execute bit set on gradlew (missing in the project folder)"
fi
log "project copied to $WORK ($(find "$WORK" -type f | wc -l) files)"

# ---- foreign-architecture packages (e.g. libicu74:arm64) -------------------
# The image already has the arm64 architecture, the Ubuntu Ports sources and the SDK's
# arm64 development libraries. Only if the snapcraft.yaml names further arm64 packages
# (stage-packages or build-packages), the package lists are refreshed here, inside
# this disposable container.
setup_arm64_apt() {
    local sources=/etc/apt/sources.list.d/ubuntu.sources
    if ! dpkg --print-foreign-architectures | grep -qx arm64; then
        [ -f "$sources" ] || die 4 "$sources not found; cannot add arm64 package sources"
        if grep -q '^Architectures:' "$sources"; then
            die 4 "unexpected Ubuntu source configuration (Architectures already set)"
        fi
        sed -i '/^Types:/a Architectures: amd64' "$sources"
        printf '%s\n' \
            'Types: deb' \
            'URIs: http://ports.ubuntu.com/ubuntu-ports/' \
            'Suites: noble noble-updates noble-backports noble-security' \
            'Components: main restricted universe multiverse' \
            'Architectures: arm64' \
            'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
            > /etc/apt/sources.list.d/ubuntu-arm64.sources
        dpkg --add-architecture arm64
    fi
    apt-get update -qq || die 4 "apt-get update failed for the arm64 package sources"
    log "arm64 package lists refreshed"
}

if [ "$ARCH" = arm64 ] && grep -Eq 'to arm64|:arm64' "$WORK/snap/snapcraft.yaml"; then
    if [ "$DRY_RUN" = 1 ]; then
        log "dry run: would refresh the arm64 package lists"
    else
        setup_arm64_apt
    fi
fi

# ---- recipes -------------------------------------------------------------------
# "shared" .NET recipe: the command sequence common to all twelve SDK .NET sample
# scripts build-snap-<arch>.sh (identical apart from the runtime identifier),
# followed by the SDK's own scripts/build-snap-<arch>.sh. The SDK scripts carry
# no execute bit in the release archive, so they are started through bash.
build_dotnet() {
    rm -rf ./publish
    dotnet publish --configuration Release --runtime "$RID" \
        --property:PublishDir=./publish --self-contained true \
        /property:GenerateFullPaths=true /property:PublishSingleFile=true \
        /property:PublishTrimmed=true /property:DebugType=None \
        /property:DebugSymbols=false || return 1
    bash "$SDK/scripts/build-snap-$ARCH.sh" || return 1
}

# "shared" C++ recipe: the commands common to the SDK C++ sample scripts
# (CMake with the BUILD_KIT for the target, then make install; the sample CMake files
# pack the snap in a post-build step). If no snap results, pack explicitly.
build_cpp() {
    local triplet
    case "$ARCH" in
        amd64) triplet=x86_64-linux-gnu ;;
        arm64) triplet=aarch64-linux-gnu ;;
    esac
    rm -rf bfbs generated build
    mkdir build
    ( cd build \
        && cmake -DBUILD_KIT="GCC $triplet" -DBUILD_SNAP=ON .. \
        && make install \
        && make clean ) || return 1
    if ! compgen -G "$WORK/*.snap" >/dev/null; then
        snapcraft pack --build-for="$ARCH" --verbosity=verbose || return 1
    fi
}

# "shared" Go recipe: the SDK's own script (snapcraft clean, snapcraft pack); the
# build-for specific settings are in the project's snapcraft.yaml (override-build).
build_go() {
    bash "$SDK/scripts/build-snap-$ARCH.sh" || return 1
}

# "shared" Node.js recipe: the commands of the SDK Node.js sample scripts. The part in
# snap/snapcraft.yaml calls the SDK's samples-node/build-node-app.sh (npm install, tsc,
# npm pack, runtime packaging); the Node runtime comes from the cache pre-seeded in the image.
build_node() {
    snapcraft clean --platform "$ARCH" || return 1
    snapcraft pack --build-for="$ARCH" --verbosity=verbose || return 1
}

# "shared" Python recipe: same commands as the Node.js one. The python plugin builds a
# virtual environment from the project (pyproject/requirements) with the pip wheels
# resolved at build time; ctrlx-datalayer and libsystemd-dev come in as stage-packages.
build_python() { build_node; }

# "shared" Java recipe: the steps of the SDK samples-java/<sample>/build-snap-<arch>.sh in
# the container copy (link to the SDK Java JARs, Gradle distribution and version catalog
# into the places the Gradle wrapper expects), then the SDK's own scripts/build-snap-<arch>.sh.
build_java() {
    [ -e java ] || ln -s "$SDK/java" java
    cp "$SDK"/oss.gradle/*.zip gradle/wrapper/ || return 1
    cp "$SDK/scripts/samples-java/libs.versions.toml" gradle/ || return 1
    bash "$SDK/scripts/build-snap-$ARCH.sh" || return 1
}

# "project" recipe: the project's own script, run in the container copy. Lines that
# call an SDK script directly (../../scripts/x.sh) are prefixed with "bash " in
# this copy only, because the SDK release archive has no execute bits and SDK
# files are never modified. "sudo" is a pass-through inside the image.
build_project() {
    bash "./$script" || return 1
}

prepare_project_script() {
    local orig
    orig=$(mktemp)
    cp "$WORK/$script" "$orig"
    sed -E -i 's#^([[:space:]]*)((\.\./)+scripts/[^[:space:]]+)#\1bash \2#' "$WORK/$script"
    if ! cmp -s "$orig" "$WORK/$script"; then
        log "container copy of $script: lines rewritten to start through bash:"
        diff "$orig" "$WORK/$script" | sed 's/^/    /' || true
    fi
    rm -f "$orig"
}

# The snapcraft.yaml of the SDK Node.js samples calls ../build-node-app.sh directly,
# which has no execute bit in the SDK release archive (SDK files are never modified).
# In the container copy of the yaml only, such a line is started through bash.
prepare_snapcraft_yaml() {
    local orig
    orig=$(mktemp)
    cp "$WORK/snap/snapcraft.yaml" "$orig"
    sed -E -i 's#^([[:space:]]+)(\$\{?SNAPCRAFT_PROJECT_DIR\}?/(\.\./)+[^[:space:]]+\.sh)[[:space:]]*$#\1bash \2#' "$WORK/snap/snapcraft.yaml"
    if ! cmp -s "$orig" "$WORK/snap/snapcraft.yaml"; then
        log "container copy of snap/snapcraft.yaml: lines rewritten to start through bash:"
        diff "$orig" "$WORK/snap/snapcraft.yaml" | sed 's/^/    /' || true
    fi
    rm -f "$orig"
}

cd "$WORK"
script="build-snap-$ARCH.sh"
case "$RECIPE" in
    auto|shared|project) ;;
    *) die 2 "unknown recipe '$RECIPE' (auto, shared or project)" ;;
esac
if [ "$RECIPE" = auto ]; then
    if [ -f "$WORK/$script" ]; then
        RECIPE=project
    elif compgen -G "$WORK/build-snap-*.sh" >/dev/null; then
        die 3 "the project has build scripts but none for $ARCH ($script); add it, or pass --recipe shared to use the built-in recipe"
    else
        RECIPE=shared
    fi
fi
if [ "$RECIPE" = project ] && [ ! -f "$WORK/$script" ]; then
    die 3 "recipe 'project' needs $script in the project folder"
fi
log "recipe: $RECIPE"

if [ "$LANG_ID" = dotnet ]; then
    mapfile -t projs < <(find "$WORK" -name '*.csproj' -not -path '*/obj/*' -not -path '*/bin/*')
    if [ "${#projs[@]}" -gt 1 ]; then
        printf '[ctrlx-build] WARNING: %s .csproj files found; .NET compiles all sources below the project folder\n' "${#projs[@]}"
        printf '[ctrlx-build]   %s\n' "${projs[@]#"$WORK"/}"
    fi
    # A solution file that points to a project path that does not exist breaks
    # "dotnet publish" when no project is named, because the solution is then used.
    for sln in "$WORK"/*.sln; do
        [ -f "$sln" ] || continue
        while IFS= read -r rel; do
            rel=${rel%$'\r'}
            [ -e "$WORK/${rel//\\//}" ] \
                || printf '[ctrlx-build] WARNING: %s references project %s, which does not exist; dotnet uses the solution when both exist\n' "${sln##*/}" "$rel"
        done < <(sed -nE 's/^Project\("[^"]*"\) = "[^"]*", "([^"]*proj)".*/\1/p' "$sln")
    done
fi

[ "$RECIPE" != project ] || prepare_project_script
prepare_snapcraft_yaml

if [ "$DRY_RUN" = 1 ]; then
    log "dry run: would run the $RECIPE recipe for $LANG_ID/$ARCH ($RID) in $WORK"
    exit 0
fi

log "building: lang=$LANG_ID arch=$ARCH name=$NAME recipe=$RECIPE"
if [ "$RECIPE" = project ]; then
    build_project || die 4 "build failed (see the log above)"
else
    "build_$LANG_ID" || die 4 "build failed (see the log above)"
fi

# ---- collect and check the snap ---------------------------------------------
mapfile -t snaps < <(find "$WORK" -maxdepth 1 -type f -name '*.snap')
[ "${#snaps[@]}" -eq 1 ] || die 5 "expected exactly one .snap in $WORK, found ${#snaps[@]}"
snap=${snaps[0]}
snapfile=$(basename "$snap")
case "$snapfile" in
    *"_${ARCH}.snap") ;;
    *) die 5 "snap file name '$snapfile' does not end in _${ARCH}.snap" ;;
esac

meta=$(unsquashfs -no-progress -cat "$snap" meta/snap.yaml) \
    || die 5 "cannot read meta/snap.yaml from $snapfile"
base=$(printf '%s\n' "$meta" | awk '/^base:/{print $2; exit}')
meta_arch=$(printf '%s\n' "$meta" | awk '/^architectures:/{f=1; next} f && /^- /{print $2; exit}')
[ "$base" = core24 ] || die 5 "snap base is '$base', expected core24"
[ "$meta_arch" = "$ARCH" ] || die 5 "snap architecture is '$meta_arch', expected $ARCH"

# Report-only ELF check (a mismatch is a warning, not a failure): machine types of all
# ELF files inside the snap. A mismatch is reported as WARN and status=warn.
case "$ARCH" in
    amd64) want='Advanced Micro Devices X86-64' ;;
    arm64) want='AArch64' ;;
esac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
unsquashfs -no-progress -no-xattrs -d "$tmp/snap" "$snap" >/dev/null \
    || die 5 "cannot unpack $snapfile for inspection"
declare -A machines=()
mismatch=0
while IFS= read -r -d '' f; do
    [ "$(head -c4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
    m=$(readelf -h "$f" 2>/dev/null | sed -n 's/^ *Machine: *//p')
    [ -n "$m" ] || m=unreadable
    machines[$m]=$(( ${machines[$m]:-0} + 1 ))
    if [ "$m" != "$want" ]; then
        mismatch=$(( mismatch + 1 ))
        printf 'WARN: %s is %s, expected %s\n' "${f#"$tmp/snap/"}" "$m" "$want" >&2
    fi
done < <(find "$tmp/snap" -type f -size +52c -print0)
elf=""
for m in "${!machines[@]}"; do elf+="${m// /_}=${machines[$m]};"; done
[ -n "$elf" ] || elf="none"

cp "$snap" "$OUT/$snapfile"
( cd "$OUT" && sha256sum "$snapfile" > "$snapfile.sha256" )
bytes=$(stat -c %s "$OUT/$snapfile")
sum=$(cut -d' ' -f1 "$OUT/$snapfile.sha256")
status=ok
[ "$mismatch" -eq 0 ] || status=warn

printf 'CTRLX_RESULT status=%s lang=%s arch=%s snap=%s bytes=%s sha256=%s base=%s elf=%s mismatches=%s\n' \
    "$status" "$LANG_ID" "$ARCH" "$snapfile" "$bytes" "$sum" "$base" "$elf" "$mismatch"
log "snap written to the project folder: $snapfile"
