#Author: Nakul Sudarshan (with help from Copilot and Claude) 

#!/usr/bin/env bash
# Read-only probe: collects the facts that decide whether and how the ctrlX builder runs on a
# machine (an App Build Environment VM created by ctrlX WORKS, or a Linux workstation).
#
# Usage:  bash ctrlx-probe.sh            writes ./ctrlx-probe-<timestamp>.txt and prints it
#
# Nothing is installed, changed or deleted. Passwords, tokens and credentials inside proxy URLs
# are masked, the host name is not recorded, no environment dump is made, and apt exception host
# names are not printed. The report still lists IP addresses and routes: keep it out of git. sudo is only
# asked "may I run it without a password?" (sudo -n true); no other command uses sudo.
set -u

OUT="./ctrlx-probe-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$OUT") 2>&1

section() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
mask() { sed -E 's#(://)[^/@[:space:]]*@#\1***@#g'; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 | head -${LINES_MAX:-40}; }

printf 'ctrlX builder probe, %s\n' "$(date -Is)"
printf 'account: %s (uid %s, gid %s), groups: %s\n' "$(id -un)" "$(id -u)" "$(id -g)" "$(id -Gn)"

section "operating system"
. /etc/os-release 2>/dev/null && printf '%s (%s)\n' "$PRETTY_NAME" "${VERSION_CODENAME:-?}"
run uname -mr
printf 'virtualisation: %s\n' "$(systemd-detect-virt 2>/dev/null || echo unknown)"
printf 'cpu model: %s\n' "$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
printf 'cpu flags vmx/svm (nested virtualisation hint): %s\n' "$(grep -c -E ' (vmx|svm) ' /proc/cpuinfo || true)"

section "resources"
printf 'CPUs: %s\n' "$(nproc)"
awk '/MemTotal|MemAvailable|SwapTotal/{printf "%s %.1f GiB\n", $1, $2/1048576}' /proc/meminfo
run df -h / "$HOME"
printf 'free inodes on /: %s\n' "$(df --output=iavail / | tail -1 | tr -d ' ')"

section "user namespaces and security modules"
for f in /proc/sys/kernel/unprivileged_userns_clone /proc/sys/user/max_user_namespaces \
         /proc/sys/kernel/apparmor_restrict_unprivileged_userns /proc/sys/kernel/apparmor_restrict_unprivileged_unconfined; do
    printf '%s = %s\n' "$f" "$( [ -r "$f" ] && cat "$f" || echo '(not present)')"
done
printf 'apparmor enabled: %s\n' "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo unknown)"
printf 'unshare --user --map-root-user works: %s\n' "$(unshare --user --map-root-user id -u 2>/dev/null || echo NO)"
printf '/etc/subuid entry: %s\n' "$(grep "^$(id -un):" /etc/subuid 2>/dev/null || echo 'none')"
printf '/etc/subgid entry: %s\n' "$(grep "^$(id -un):" /etc/subgid 2>/dev/null || echo 'none')"
printf 'newuidmap/newgidmap: %s / %s\n' "$(command -v newuidmap || echo missing)" "$(command -v newgidmap || echo missing)"

section "cgroups and systemd (user session)"
printf 'cgroup filesystem: %s\n' "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)"
printf 'XDG_RUNTIME_DIR: %s\n' "${XDG_RUNTIME_DIR:-(unset)}"
if have loginctl; then run loginctl show-user "$(id -un)" -p Linger -p State -p RuntimePath; fi
uc="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/cgroup.controllers"
printf 'delegated controllers (user manager): %s\n' "$( [ -r "$uc" ] && cat "$uc" || echo '(not readable / no user manager)')"
printf 'dbus-user-session installed: %s\n' "$(dpkg -s dbus-user-session 2>/dev/null | awk '/^Status/{print $4}' || true)"
have systemctl && printf 'systemctl --user works: %s\n' "$(systemctl --user is-system-running 2>&1 | head -1)"

section "sudo"
if have sudo; then
    if sudo -n true 2>/dev/null; then echo "sudo without password: yes"; else echo "sudo without password: no (a password prompt would be needed)"; fi
else echo "sudo: not installed"; fi

section "network and proxy (credentials masked)"
for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
    printf '%s=%s\n' "$v" "$(printenv "$v" | mask)"
done
grep -i proxy /etc/environment 2>/dev/null | mask
printf 'apt proxy lines (host names hidden, DIRECT exceptions counted): global=%s direct=%s\n' \
    "$(grep -rihE '^Acquire::https?::Proxy[[:space:]]+"' /etc/apt/apt.conf /etc/apt/apt.conf.d/ 2>/dev/null | mask | sed -E 's#(://[^:/]+).*#\1…#' | head -2 | tr '\n' ' ')" \
    "$(grep -rihc 'DIRECT' /etc/apt/apt.conf.d/ 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo 0)"
run ip -brief address
run ip route
for u in https://download.docker.com https://registry-1.docker.io https://api.snapcraft.io https://github.com https://archive.ubuntu.com; do
    printf '%-40s %s\n' "$u" "$(curl -sS -m 60 -o /dev/null -w '%{http_code}' "$u" 2>&1 | head -c 90)"
done
printf 'custom CA certificates in /usr/local/share/ca-certificates: %s\n' "$(ls /usr/local/share/ca-certificates 2>/dev/null | wc -l)"

section "installed tools"
for t in docker dockerd rootlesskit slirp4netns pasta passt containerd runc snap snapcraft lxc lxd git curl wget tar sha256sum unzip jq bash python3 code; do
    printf '%-14s %s\n' "$t" "$(command -v "$t" || echo '-')"
done
have docker && run docker --version
have snap && run snap list
for p in docker-ce docker-ce-cli docker-ce-rootless-extras docker.io podman uidmap slirp4netns passt buildah; do
    printf '%-26s %s\n' "$p" "$(dpkg -s "$p" 2>/dev/null | awk '/^Version/{print $2}' | head -1 || true)"
done
printf 'docker apt source present: %s\n' "$(grep -rl download.docker.com /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | head -1 || true)"
printf 'groups docker/lxd exist: %s / %s\n' "$(getent group docker | cut -d: -f1)" "$(getent group lxd | cut -d: -f1)"
printf 'rootful docker.service: %s / socket: %s\n' "$(systemctl is-enabled docker.service 2>&1 | head -1)" "$(systemctl is-active docker.socket 2>&1 | head -1)"

section "ctrlX / SDK"
for d in "$HOME/ctrlx-automation-sdk" "$HOME/scripts"; do printf '%s: %s\n' "$d" "$( [ -d "$d" ] && echo present || echo absent)"; done
[ -d "$HOME/ctrlx-automation-sdk/.git" ] && git -C "$HOME/ctrlx-automation-sdk" describe --tags --always 2>/dev/null
grep -E 'SNAPCRAFT|http_proxy' /etc/environment 2>/dev/null | mask

section "rootless Docker (only if present for this account)"
if have docker || [ -x "$HOME/bin/docker" ]; then
    D=$(command -v docker || echo "$HOME/bin/docker")
    if [ -z "${DOCKER_HOST:-}" ] && [ -S "/run/user/$(id -u)/docker.sock" ]; then export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"; fi
    printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-(unset)}"
    "$D" version --format 'client {{.Client.Version}} server {{.Server.Version}} api {{.Server.APIVersion}}' 2>&1 | head -3
    "$D" info --format 'security={{json .SecurityOptions}} storage={{.Driver}} cgroup={{.CgroupVersion}}/{{.CgroupDriver}} cpus={{.NCPU}} mem={{.MemTotal}} rootdir={{.DockerRootDir}} store={{.DriverStatus}}' 2>&1 | head -3
    "$D" info 2>&1 | grep -iE 'rootless|userns|network|plugins|proxy|runtimes|init binary|Buildx|buildx' | head -12
    "$D" system df 2>&1 | head -8
    for b in dockerd rootlesskit dockerd-rootless.sh dockerd-rootless-setuptool.sh docker-proxy vpnkit slirp4netns pasta; do
        printf '%-28s %s\n' "$b" "$(command -v "$b" || ls "$HOME/bin/$b" 2>/dev/null || echo -)"
    done
    for b in rootlesskit dockerd; do
        p=$(command -v "$b" || ls "$HOME/bin/$b" 2>/dev/null)
        [ -n "${p:-}" ] && printf '%s -> %s\n' "$b" "$("$p" --version 2>&1 | head -1)"
    done
    section "rootless Docker: systemd user unit and overrides"
    run systemctl --user status docker.service --no-pager -n 0
    for f in "$HOME/.config/systemd/user/docker.service" "$HOME/.config/systemd/user/docker.service.d/"*.conf /usr/lib/systemd/user/docker.service; do
        [ -f "$f" ] && { printf -- '--- %s\n' "$f"; mask < "$f" | head -40; }
    done
    for f in "$HOME/.config/docker/daemon.json" "$HOME/.docker/config.json"; do
        [ -f "$f" ] && { printf -- '--- %s (auth entries removed)\n' "$f"; grep -vE '"auth"|"identitytoken"|"password"' "$f" | mask | head -30; }
    done
    section "rootless Docker: AppArmor profiles for rootlesskit"
    ls -l /etc/apparmor.d 2>/dev/null | grep -iE 'rootless|docker' | head
    for f in /etc/apparmor.d/*rootlesskit*; do [ -f "$f" ] && { printf -- '--- %s\n' "$f"; cat "$f"; }; done
    section "rootless Docker: user-visible shell setup"
    grep -nE 'DOCKER_HOST|XDG_RUNTIME_DIR|/bin|docker' "$HOME/.bashrc" "$HOME/.profile" 2>/dev/null | mask | head -12
else
    echo "no docker client found for this account"
fi

printf '\nReport written to %s\n' "$OUT"
