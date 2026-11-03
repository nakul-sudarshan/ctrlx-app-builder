# ctrlX app builder

> **Unofficial and unsupported.** This repository is the result of an **internship project**. It is a
> proof of concept, **not an official Bosch Rexroth product**, and comes **without support, warranty or
> maintenance commitment** (see `LICENSE`). Use at own risk and check every result before relying on it.

Builds a **ctrlX app** (a Snapcraft `.snap`) inside a throw-away Docker container, for the
CPU architectures **amd64** and **arm64**, from a project folder that contains `snap/snapcraft.yaml`.

Supported: **Core24 only** (`base: core24`), six languages: **C++, .NET, Go, Java, Node.js, Python**.
Projects with `base: core22` are refused on purpose.

The ctrlX SDK does **not** have to be installed. The builder image downloads its own copy of the
SDK and every tool, checks the downloads against pinned checksums, and the project folder is
only read from, plus the finished snap written back to it.

> **Status of the working solution paths**
>
> | Path | What it is | State |
> |---|---|---|
> | **A** | Ubuntu 24.04 machine, rootless Docker | Tested on Ubuntu 24.04 with rootless Docker: all six languages, amd64 and arm64, 118 builds of the SDK 4.6.0 sample projects. The setup steps in Part 2 follow the Docker documentation. |
> | **B** | ctrlX WORKS **App Build Environment** (QEMU/VirtualBox VM) | The App Build Environment started with the SDK's own Linux launcher (KVM) was set up following Part 2 and built 11 sample projects/architectures (dotnet, C++, Go, Java, Node.js, Python; amd64 and arm64). Lingering and the rootless service were confirmed to survive a reboot. |
> | **C** | Docker on any computer, one file `Dockerfile.single` | Tested to be working on an **amd64 ctrlX CORE X7**, reached over SSH from VS Code on a Windows PC. **Not tested with Docker running directly on Windows (for example Docker Desktop).** |
>

---

## Contents

1. [Which path to choose](#1-which-path-to-choose)
2. [Path A and B: install rootless Docker (Ubuntu or App Build Environment)](#2-path-a-and-b-install-rootless-docker)
3. [Path B only: reach the App Build Environment from Windows (SSH, VS Code)](#3-path-b-only-reach-the-app-build-environment-from-windows)
4. [Get the builder and prepare a project](#4-get-the-builder-and-prepare-a-project)
5. [Build a snap (Paths A and B)](#5-build-a-snap-paths-a-and-b)
6. [Path C: plain Docker with one file](#6-path-c-plain-docker-with-one-file-dockerfilesingle)
7. [Read the result](#7-read-the-result)
8. [Something went wrong](#8-something-went-wrong)
9. [Cleaning up and disk space](#9-cleaning-up-and-disk-space)
10. [Limits and what is not covered](#10-limits-and-what-is-not-covered)
11. [What is in this folder](#11-what-is-in-this-folder)

---

## 1. Which path to choose

Answer the questions from the top; the first "yes" decides.

1. **The ctrlX WORKS App Build Environment (the Ubuntu VM that ctrlX WORKS creates) is already
   initialised and is how builds are done today?** -> **Path B.** Do Part 3, Part 2, Part 4, Part 5.
2. **A normal Ubuntu 24.04 computer (or VM) with `sudo` rights is available?** -> **Path A.**
   Do Part 2, Part 4, Part 5.
3. **Only Docker is available (for example Docker Desktop on Windows), or the Ubuntu steps are
   too much?** -> **Path C.** Do Part 6 (and Part 4 for the project layout).

Why rootless Docker for Paths A and B: the container then runs without any special rights on the
host. Never add a user to the `docker` group, never start containers with `--privileged`, and
never use a Docker that runs as root for this. Path C with Docker Desktop is the exception that
cannot be avoided on Windows; see the notes in Part 6.

Rough sizes to plan for (measured on an Ubuntu 24.04 workstation):

| Item | Size |
|---|---|
| Builder image | 5.8 GB |
| Build cache after the first image build | about 9 GB more |
| One finished snap | roughly 10 to 60 MB |
| First image build | about 8 minutes on a fast connection (more on a VM without hardware acceleration) |
| One snap build afterwards | 25 s (C++, .NET, Node.js, Go) up to 90 s (Java) on the native Ubuntu workstation on which it was tested |

The App Build Environment disk is 32 GB by default, so the image and cache fit, but not much
else. See [Part 9](#9-cleaning-up-and-disk-space).

---

## 2. Path A and B: install rootless Docker

Needs an **Ubuntu 24.04** system, a normal (non-root) account that is allowed to use `sudo`, and
internet access. The App Build Environment is Ubuntu Server 24.04 and its user `boschrexroth`
has `sudo` without a password.

Everything below is typed into a **terminal on that Ubuntu system** (for Path B: the SSH terminal
from Part 3). Copy one block at a time. Lines starting with `#` are comments and can be pasted
as well.

> Do **not** run these commands as `root` and do **not** put `sudo` in front of the commands
> that do not have it. Rootless Docker belongs to the normal account.

### 2.1 Check the starting point

```bash
lsb_release -ds          # expected: Ubuntu 24.04.x LTS
uname -m                 # expected: x86_64
nproc; free -h; df -h /  # CPUs, memory, free disk
```

Needed: `x86_64`, at least about 15 GB free disk space, 4 GB RAM (more is better; see
[Part 8](#8-something-went-wrong) if a build is "Killed").

Optional: run the read-only probe and keep its output for troubleshooting.
It changes nothing and writes `ctrlx-probe-<time>.txt` into the current folder:

```bash
bash ctrlx-probe.sh
```

### 2.2 Install the helper packages

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl uidmap dbus-user-session slirp4netns
```

What these do: `uidmap` lets a normal account map extra user IDs, which rootless containers need;
`dbus-user-session` lets the account run its own background services; `slirp4netns` gives the
rootless Docker its network.

On a fresh App Build Environment, `uidmap` (programs `newuidmap` and `newgidmap`) and `slirp4netns`
were found **missing**, `dbus-user-session` was already installed, and `sudo` needs no password.

### 2.3 Add the official Docker package source

This is the signed package repository of Docker Inc. (taken from the Docker documentation).

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

### 2.4 Install Docker

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-ce-rootless-extras
```

The command also pulls in `docker-compose-plugin` and `pigz` as dependencies (harmless). On 02-11-2026 the
repository offered Docker **29.9.2**, containerd.io 2.4.2 and buildx 0.38.1. The tested setup used **Docker 29.9.2**. Newer versions are expected to work, but only 29.9.2 has been tested. To install exactly that version, list what is available and name it:

```bash
apt-cache madison docker-ce | head
# then, with the full version string from the list, for example:
# sudo apt-get install -y docker-ce=<version> docker-ce-cli=<version> docker-ce-rootless-extras=<version> containerd.io docker-buildx-plugin
```

### 2.5 Switch the system-wide Docker off

Installing the package starts a Docker that runs as root. That one is not wanted. It is switched
off and disabled (the packages stay installed because they contain the rootless programs).

```bash
sudo systemctl disable --now docker.service docker.socket
sudo rm -f /var/run/docker.sock
```

### 2.6 Check the user ID ranges

```bash
grep "^$USER:" /etc/subuid /etc/subgid
```

Expected: one line in each file, like `boschrexroth:165536:65536` (the first number differs from machine to machine). **If nothing is printed**, add the
ranges and run the grep again:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
grep "^$USER:" /etc/subuid /etc/subgid
```

### 2.7 Set up rootless Docker for this account

```bash
dockerd-rootless-setuptool.sh install
```

(No `sudo`.) The tool prints several lines and ends with something like
`Installed docker.service successfully` and a hint to set `DOCKER_HOST`. If it complains about
AppArmor or "unprivileged user namespaces", see [Part 8](#8-something-went-wrong).

Let the service keep running when no one is logged in, and start it at boot:

```bash
sudo loginctl enable-linger "$USER"
systemctl --user enable --now docker
```

The setup tool also creates a Docker CLI "context" called `rootless` and switches to it, so `docker`
already talks to the right daemon. Setting `DOCKER_HOST` as well makes this independent of the context:

```bash
echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc
source ~/.bashrc
```

> **App Build Environment only:** the first time a terminal runs `~/.bashrc` (the `source ~/.bashrc` above does
> it too) the VM shows its own initialisation check: "Hit ENTER to continue", then "Remove this check script from
> ~/.bashrc? Y/n". Press Enter, then type `y` and press Enter. It only reports problems of the first-boot installation.

### 2.8 Test it

```bash
docker --version
docker info --format '{{json .SecurityOptions}}'
docker run --rm hello-world
```

Expected: `docker --version` prints
`Docker version 29.9.2` or whatever latest version of Docker was installed; `docker info` prints `["name=seccomp,profile=builtin","name=rootless","name=cgroupns"]`.
In the output of the setup tool (2.7) the lines "No io.max ... support" are warnings that can be ignored (rootless
Docker cannot limit disk I/O). On the App Build Environment the AppArmor profile for `/usr/bin/rootlesskit` already
exists (`ls /etc/apparmor.d | grep rootless` shows `rootlesskit`), so no AppArmor change is needed there.
The second command must print a line that contains `name=rootless`. The third prints
"Hello from Docker!". If both work, rootless Docker is ready. If the second prints no
`rootless`, the wrong Docker is being used: check `echo $DOCKER_HOST` (must show
`unix:///run/user/<number>/docker.sock`).

### 2.9 Check that the download sites are reachable

The image build downloads from several sites. Test them before the long build starts. Each line
should print a three-digit number (200, 307, 400 and 404 all mean
"reachable"); `000` or a timeout means the site cannot be reached.

```bash
for u in https://api.snapcraft.io https://github.com https://go.dev https://nodejs.org \
         https://builds.dotnet.microsoft.com https://services.gradle.org https://ports.ubuntu.com \
         https://registry-1.docker.io https://download.docker.com; do
  printf '%-45s %s\n' "$u" "$(curl -sS -m 60 -o /dev/null -w '%{http_code}' "$u" 2>&1 | tail -c 60)"
done
```

`https://api.snapcraft.io` can be **slow**: from the office network a plain request needed up to about 20 seconds
to answer. The builder image takes Snapcraft and the
Core24 base from that site, so it must answer eventually; a long wait is not an error.

---

## 3. Path B only: reach the App Build Environment from Windows

**Skip this part for Path A.** Facts about the App Build Environment that come from the SDK's own
scripts in `scripts/environment/`: a QEMU virtual machine (Ubuntu Server 24.04, 4 CPUs, 4 GB RAM,
32 GB disk) whose port 22 is reachable from Windows at **localhost port 10022**; user
`boschrexroth`, password `boschrexroth`.

### 3.1 Start the VM

Start the App Build Environment from ctrlX WORKS (or with its start script). **The very first start
is only the installation:** the VM installs its packages (several minutes), creates the user
`boschrexroth` as the very last step, prints "Installation Finished" and **switches itself off**.
SSH login is not possible before that (a "Permission denied" with the correct password means the
installation is not finished). Start the App Build Environment a **second** time; after about one to two
minutes it accepts logins. Keep the VM window open: closing it stops the VM.

### 3.2 Connect with Command Prompt or PowerShell (simplest test)

```
ssh -p 10022 boschrexroth@localhost
```

Answer `yes` to the question about the host key, type the password `boschrexroth`, press Enter. A prompt like `boschrexroth@...:~$` means success. Every command in
Part 2 is typed there. `exit` leaves the VM (the VM keeps running).

### 3.3 Connect with VS Code (Remote-SSH)

1. In VS Code open Extensions (`Ctrl+Shift+X`), search for **Remote - SSH** (publisher
   Microsoft) and install it.
2. Press `F1`, type **Remote-SSH: Open SSH Configuration File...**, choose the first file offered
   and add:
   ```
   Host ctrlx-build-env
       HostName localhost
       Port 10022
       User boschrexroth
   ```
   Save the file.
3. Press `F1`, type **Remote-SSH: Connect to Host...**, choose `ctrlx-build-env`, choose
   **Linux** if asked, accept the fingerprint, enter the password `boschrexroth`.
4. A new VS Code window opens, bottom left shows `SSH: ctrlx-build-env`. Open a terminal with
   `` Ctrl+` ``. This terminal is inside the VM; Part 2 is typed there.
5. **File > Open Folder...** opens a folder of the VM in the VS Code explorer. Files can be
   dragged from Windows into that explorer to upload them, and a file (for example a finished
   `.snap`) can be downloaded with a right click > **Download...**.

### 3.4 The VM has no hardware acceleration?

In the first inspection (an App Build Environment inside another VM, so certainly without
acceleration) `lscpu` showed the processor as "QEMU Virtual CPU version 2.5+".

Without Windows Hypervisor Platform the VM is emulated in software and is several times slower.
Everything still works, the first image build just takes longer (plan for an hour rather than
minutes) and a Java build can take many minutes. Check in the VM:

```bash
lscpu | grep -i -E 'hypervisor|model name'
```

This only tells that it is a VM; whether acceleration is on is decided by the VM start script
(`whpx` means accelerated, `tcg` means software emulation). Nothing needs to be changed for the
builder to work.

### 3.5 Corporate network / proxy

If the Windows PC reaches the internet only through a corporate proxy (the App Build
Environment's "proxy" variant, with `px.exe`), the steps in this document **do not cover it yet**:
the Docker daemon and the image build need proxy settings, and the VM gateway address `10.0.2.2`
may clash with the rootless Docker network. See [Part 10](#10-limits-and-what-is-not-covered).

---

## 4. Get the builder and prepare a project

### 4.1 Get the builder files

The builder is this folder (`ctrlx-build/`). Get it into the Ubuntu system, either

- by cloning the repository it lives in (replace `<repository-url>`):
  ```bash
  git clone <repository-url> ~/ctrlx-build
  ```
- or by uploading the folder (Path B: drag it into the VS Code explorer, or use `scp -P 10022 -r ctrlx-build boschrexroth@localhost:~/`).

If files were edited or zipped on Windows, make sure they still have Unix line endings (LF). The
`.gitattributes` file in this folder asks git to keep LF. A script with Windows line endings
fails with messages like `bash\r: No such file or directory`; see [Part 8](#8-something-went-wrong).

### 4.2 Project layout

The builder lives **inside** the project folder:

```
my-app/                      <- the project folder; its NAME matters, see below
  snap/snapcraft.yaml        <- required, must say: base: core24
  <sources: .csproj / CMakeLists.txt / go.mod / package.json / build.gradle / pyproject.toml ...>
  ctrlx-build/               <- this builder folder, copied here
```

Rules:

- The folder name `my-app` is used inside the build as `/sdk/<language-group>/my-app`. Keep it to
  letters, digits, dots, dashes and underscores (no spaces). It is **not** the snap name; the snap name comes from
  `snapcraft.yaml`.
- A project written for `base: core22` is refused (exit code 3). The project has to be ported to
  `core24` first.
- Sample projects of the ctrlX SDK work as they are (they contain their own
  `build-snap-<arch>.sh`; the builder uses those if present, see "recipe" below).

### 4.3 Try it with an SDK sample (recommended first test)

This uses a copy of the public SDK only to obtain a sample. The builder does not need that copy.

```bash
cd ~
git clone --depth 1 --branch 4.6.0 https://github.com/boschrexroth/ctrlx-automation-sdk.git
cp -r ctrlx-automation-sdk/samples-net/hello.world ~/hello.world
cp -r ~/ctrlx-build ~/hello.world/ctrlx-build
```

The sample is now `~/hello.world` and contains `ctrlx-build/`.

---

## 5. Build a snap (Paths A and B)

From inside the project folder:

```bash
cd ~/hello.world
./ctrlx-build/ctrlx-build.sh
```

(If `Permission denied` appears, the execute bit was lost on the way: use
`bash ./ctrlx-build/ctrlx-build.sh` instead.)

What happens:

1. The launcher finds the language and asks `Detected language: dotnet. Use it? [Y/n]`. Press Enter.
2. It asks for the architecture: type `1` for **amd64** (PC / ctrlX CORE X5, X7) or `2` for **arm64**
   (ctrlX CORE X3).
3. **First time only:** the builder image is created ("Builder image ... not found; building it").
   This downloads several GB and takes minutes (see the table in Part 1). Do not interrupt. The
   later runs reuse the image + cache and start in seconds.
4. The build runs. Output scrolls by and is also saved in `ctrlx-build/logs/`.
5. At the end one line starts with `CTRLX_RESULT`. Part 7 explains it.

Without questions (useful for scripts):

```bash
./ctrlx-build/ctrlx-build.sh --lang dotnet --arch arm64
```

All options:

| Option | Meaning |
|---|---|
| `--lang cpp\|dotnet\|go\|java\|node\|python` | Language. Detected from the project files if omitted. |
| `--arch amd64\|arm64` | Target CPU. Asked if omitted. Both architectures are built on an amd64 machine (arm64 is cross-built). |
| `--project DIR` | Build another folder than the one that contains `ctrlx-build/`. |
| `--recipe auto\|shared\|project` | **auto** (default): use the project's own `build-snap-<arch>.sh` if there is one for this architecture, otherwise the built-in recipe. **shared**: always the built-in recipe of the language. **project**: always the project's own script (error if there is none). |
| `--build-image` | Only create the builder image, then stop. |
| `--detect-only` | Only print the detected language, then stop (builds nothing). |

Exit codes: `0` ok, `2` wrong usage or Docker problem, `3` project not supported (for example
`core22`), `4` the build itself failed, `5` no snap or a wrong snap was produced.

---

## 6. Path C: plain Docker with one file (`Dockerfile.single`)

This path needs **only Docker** and the one file `Dockerfile.single`. It does not use the
launcher script or the rootless setup. Typical use: a Linux machine where Docker already runs.

> **Notice: untested on Windows.** `Dockerfile.single` has been tested to be working on an amd64 ctrlX
> CORE X7 (Linux), reached over SSH from VS Code on a Windows PC. Docker running **directly on
> Windows** (Docker Desktop) has **not** been tested, and the PowerShell command in Part 6.3 is
> derived from the Linux one, not run. No support is provided for it.

### 6.1 What is needed

- Docker with **Linux containers** (on Windows: Docker Desktop with the WSL 2 backend; Windows
  containers do not work). Docker 23 or newer.
- An **x86-64** computer. A Windows-on-ARM computer would pull the wrong CPU variant and is not supported.
- Internet access to the download sites (Ubuntu, GitHub, Microsoft, go.dev, nodejs.org,
  Eclipse Adoptium, Gradle, Snapcraft). A corporate proxy is **not handled** (Part 10).
- Free disk space as in Part 1, and enough memory given to Docker. In Docker Desktop:
  Settings > Resources. Start with 6 GB or more; Java builds need the most.
- Docker Desktop is licence-restricted for larger companies. Check with the IT department before
  installing it.

Test Docker first (in PowerShell, Command Prompt, or any terminal):

```
docker version
docker run --rm hello-world
```

### 6.2 Step 1: build the builder image (one time only)

Open a terminal **in the folder that contains `Dockerfile.single`** (in Windows Explorer: open
the folder, click the address bar, type `powershell`, press Enter). Then:

```
docker build --tag ctrlx-builder:single --file Dockerfile.single .
```

Explained:

- `docker build` creates an image from a recipe.
- `--tag ctrlx-builder:single` gives the image a name so that the next step can find it.
  (The tag is only a label; it is not part of the file.)
- `--file Dockerfile.single` names the recipe.
- The final `.` is the "build context": the folder whose files the build may see. Everything in
  it is sent to Docker, so use a folder that contains little more than this file.

It downloads and installs everything, takes minutes (see Part 1) and prints a lot. It ends with a
line like `naming to docker.io/library/ctrlx-builder:single`. During the build a step checks that
the build script embedded in the file is unchanged (`sha256sum --check`). If that step fails,
the file was altered on the way, most likely by Windows line-ending conversion (Part 8).

Check that the image exists:

```
docker image ls ctrlx-builder
```

### 6.3 Step 2: build a snap

The container needs the **project folder** twice: read-only as `/project` and writable as `/out`
(where the finished snap is written). It needs four words telling it what to do:

| Word | Value |
|---|---|
| `--lang` | `cpp`, `dotnet`, `go`, `java`, `node` or `python` |
| `--arch` | `amd64` or `arm64` |
| `--name` | the project **folder name** (not the snap name) |
| `--recipe` | `auto` (as in Part 5) |

**Windows PowerShell**, started inside the project folder (the folder that contains `snap`):

```powershell
docker run --rm `
  --volume "${PWD}:/project:ro" `
  --volume "${PWD}:/out" `
  ctrlx-builder:single `
  --lang dotnet --arch amd64 --name (Split-Path -Leaf $PWD) --recipe auto
```

**Linux, macOS, WSL, Git Bash**, started inside the project folder:

```bash
docker run --rm \
  --volume "$PWD:/project:ro" \
  --volume "$PWD:/out" \
  ctrlx-builder:single \
  --lang dotnet --arch amd64 --name "$(basename "$PWD")" --recipe auto
```

Explained:

- `docker run` starts a container from the image.
- `--rm` deletes the container as soon as it finishes. The image stays.
- `--volume "<folder>:/project:ro"` shows the current folder to the container at `/project`,
  **read-only** (`ro`): the build cannot change the sources.
- `--volume "<folder>:/out"` shows the same folder again at `/out`, writable: only the finished
  `.snap` and its `.sha256` file are written there.
- `${PWD}` (PowerShell) and `$PWD` (Bash) mean "the current folder". On Windows this becomes
  something like `C:\Users\me\my-app`, which Docker Desktop accepts.
- Everything after the image name goes to the build script inside the container.
- The command prints the build output; the last line begins with `CTRLX_RESULT` (Part 7).
- To keep a log, append `2>&1 | Tee-Object build.log` (PowerShell) or `2>&1 | tee build.log` (Bash).

Run it a second time with `--arch arm64` to get the arm64 snap.

#### Project-script-only variant: `Dockerfile.norecipe`

`Dockerfile.norecipe` is a standalone copy with the same tools, but without built-in
build recipes or a `--recipe` option. The project must contain `build-snap-amd64.sh`
or `build-snap-arm64.sh` for the selected architecture; a missing script is rejected.
The selected script is run through Bash from the container copy of the project.
SDK-relative paths, script compatibility adjustments, snap checks and output files
are handled as in `Dockerfile.single`.

Build the image from the folder containing `Dockerfile.norecipe` (Bash):

```bash
docker build --tag ctrlx-builder:norecipe --iidfile .image-id --file Dockerfile.norecipe .
```

Then run the build, replacing the project path, language, architecture and folder name
as needed. `.image-id` must refer to the image built above:

```bash
docker run --rm \
  --volume "/path/to/project:/project:ro" \
  --volume "/path/to/project:/out" \
  "$(cat .image-id)" \
  --lang dotnet --arch amd64 --name my-app
```

The existing Dockerfiles and launcher are unchanged. This variant is maintained
separately, is not regenerated by `make-single-dockerfile.sh`, and is used with the
plain Docker commands above, not `ctrlx-build.sh`. After editing the embedded script,
its SHA-256 value in the final `RUN` instruction must also be updated.

### 6.4 Differences to Paths A and B

- Docker Desktop's engine is **not** rootless. The container itself still gets no extra rights
  (no `--privileged`, no Docker socket), and Docker Desktop runs inside its own VM, but the
  rootless safety property of Paths A and B is not present. The launcher
  `ctrlx-build.sh` refuses such a Docker unless `CTRLX_ALLOW_ROOTFUL=1` is set; with the plain
  commands above that check does not apply.
- Files in a Windows folder may have no Unix execute bits. Files that must be executable inside the snap
  (for example a start script such as `bin/run` of a Java project) then trigger the warning
  `no execute bit on ...` in the log, and snap packing is likely to fail late with "should be
  executable". Docker Desktop may or may not report execute bits for mounted Windows folders; this has
  not been tried. Remedy: keep the project in a Linux file system (WSL 2: a folder under
  `\\wsl$\<distribution>\home\...`, or any Linux machine) and build there, with the sources taken from
  git so that the execute bits are kept.
- Mounted Windows folders are slower than Linux folders.
- Output ownership: on Linux with rootless Docker the finished files belong to the normal user. On
  Docker Desktop the files appear as owned by the Windows user; this was not examined further.

---

## 7. Read the result

The last line of a build looks like this:

```
CTRLX_RESULT status=ok lang=dotnet arch=amd64 snap=hello.world_1.0.0_amd64.snap bytes=16973824 sha256=... base=core24 elf=... mismatches=0
```

| Field | Meaning |
|---|---|
| `status=ok` | Snap built; every compiled file inside is for the requested CPU. |
| `status=warn` | Snap built, but some files inside are for a **different** CPU (see below). Not a build error. |
| `snap=` | File name of the snap, written into the project folder. |
| `sha256=` | Checksum of the snap; the same value is in `<snap>.sha256`. |
| `base=core24` | The base the snap was built for. |
| `mismatches=` | Number of files inside the snap whose CPU does not match the target. |

`warn` is expected for projects that use the ctrlX **Data Layer** (the SDK delivers its Debian
packages with mixed CPU content) and for some Python and Java projects. Whether such content is
acceptable is a policy decision that is not made yet: treat `warn` as "built, needs a look".
`mismatches=0` and `status=ok` is the clean case.

Where to find the files: in the project folder, `<name>_<version>_<arch>.snap` and
`<name>_<version>_<arch>.snap.sha256`. In Paths A and B the log is in `ctrlx-build/logs/`.

Builds are **not bit-for-bit reproducible**: building twice gives two different checksums for the
same sources. That is normal.

Install the snap on a ctrlX CORE with the usual ctrlX OS UI procedure as defined [here](https://community.boschrexroth.com/ctrlx-automation-how-tos-qmglrz33/post/ctrlx-device-portal---how-to-install-apps-and-licenses-on-the-device-OijxRl2apUpYHVs)

---

## 8. Something went wrong

| Message or symptom | Likely cause and fix |
|---|---|
| `docker: command not found` | Docker is not installed (Part 2.4) or the terminal is old: open a new terminal. |
| `cannot talk to the Docker daemon (rootless Docker running for this user?)` | Run `systemctl --user status docker`. If it is not active: `systemctl --user start docker`. Check `echo $DOCKER_HOST` and Part 2.7. After a reboot the service needs `loginctl enable-linger` (Part 2.7). |
| `rootless Docker is required ...` | The Docker in use is the root one. Redo Part 2.5 and Part 2.7, open a new terminal. |
| `dockerd-rootless-setuptool.sh: ... unprivileged user namespaces` or AppArmor / `permission denied` while creating the network | Ubuntu 24.04 blocks user namespaces for programs without an AppArmor profile. The package `docker-ce-rootless-extras` should bring the profile. Check `ls /etc/apparmor.d | grep -i rootless` and `sysctl kernel.apparmor_restrict_unprivileged_userns`. Search the output of `dockerd-rootless-setuptool.sh install` for the profile text it prints; create the file it names as `root` and run `sudo systemctl reload apparmor`. This case has not been seen on a clean machine. |
| `systemctl --user` says "Failed to connect to bus" | The session has no user manager. Log out and in again after `enable-linger`, or reboot the VM. Check `echo $XDG_RUNTIME_DIR` (must be `/run/user/<number>`). |
| `snap/snapcraft.yaml not found` | The terminal is not in the project folder, or the builder folder is not inside the project (Part 4.2). Use `--project DIR`. |
| Exit code 3, "core22" | The project is a Core22 project. Not supported; port it to `base: core24`. |
| `$'\r': command not found`, `bash\r: No such file`, `/usr/bin/env: 'bash\r'` | The file has Windows line endings. Convert: `sed -i 's/\r$//' ctrlx-build.sh container-build.sh` (and the other scripts), or download/clone again with LF endings. For `Dockerfile.single`, get the original file again; do not open and re-save it in an editor that changes line endings. |
| `sha256sum: WARNING` / `FAILED` during the image build of `Dockerfile.single` | The embedded script differs from what the file claims. The file was modified or its line endings were changed. Get a fresh copy. |
| Download errors, `x509`, `certificate signed by unknown authority`, timeouts during the image build | The network blocks or intercepts the download. Proxies and company CA certificates are not handled (Part 10). Test the path from a network without them. |
| `curl: (35) Recv failure: Connection reset by peer` (or other `curl` download errors) during the image build, usually at `api.snapcraft.io` | A download was cut off; that site is slow and sometimes resets connections. Run the same command again: the steps that already finished are reused and only the failed download is repeated. Several repeats in a row point to the network (proxy, firewall); see Part 2.9 and Part 10. |
| Build ends with `Killed`, or exit code `137` | Out of memory. Add swap on Ubuntu (a 4 GB swap file: `sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile`; not permanent, not yet tested on the VM) or give Docker Desktop more memory. Java projects need the most. |
| `no space left on device` | Disk full. See Part 9. |
| Exit code 4 | The build step inside the container failed. Open the last screen of the log (`ctrlx-build/logs/`) and look for the first line with `error`. Typical causes are project-side: a wrong path in a `.sln`, a missing file that `.gitignore` hid, a package version that does not exist in the SDK feed. |
| Exit code 5 | The build finished but no (or a wrong) snap was produced. Look at the end of the log. |
| `Permission denied` when starting `ctrlx-build.sh` | The execute bit was lost (zip, Windows). Use `bash ./ctrlx-build/ctrlx-build.sh`. |
| A source folder of an SDK sample from the **release ZIP** fails with "permission denied" in a script | The ZIP carries no Unix file modes. Use a `git clone` of the SDK instead (Part 4.3). |

---

## 9. Cleaning up and disk space

See what Docker uses:

```bash
docker system df
```

- The finished containers are deleted automatically (`--rm`).
- The **builder image** (5.8 GB) is needed for every build. Remove it only to reclaim space; the
  next build then creates it again. `docker image ls` shows its name; remove it with
  `docker image rm <name:tag>`.
- The **build cache** (about 9 GB after the first image build) only speeds up a repeated image
  build. It can be removed safely, at the price of re-downloading everything if the image is
  built again:
  ```bash
  docker builder prune
  ```
  This deletes the build cache of the current Docker only, not images or containers.
- Finished snaps are ordinary files in the project folder. Delete them like any file.

Do not run `docker system prune -a` while the builder image is still wanted: it removes every image
that is not in use by a container, including the builder image.

---

## 10. Limits and what is not covered

- **Unofficial, unsupported proof of concept.** Created as an internship project; not an official Bosch Rexroth product; no support, no maintenance commitment, no warranty.
- **Core24 only.** Core22 and older are refused.
- **Nothing has been run on a ctrlX CORE.** Builds are checked for the target CPU by reading the
  compiled files in the snap, not by running them.
- **`status=warn` is not decided policy.** Which mixed-CPU files are acceptable is an open design
  item.
- **Python:** cross-building Python dependencies for arm64 uses ready-made wheels only; a missing
  arm64 wheel is not built from source yet.
- **Corporate proxy and company CA certificates** are not supported. This includes the App Build
  Environment's proxy variant (`px.exe`, gateway `10.0.2.2`).
- **Docker running directly on Windows** (Path C, for example Docker Desktop) is **untested**. Path C was reported working once, on an amd64 ctrlX CORE X7.
- **Windows on ARM and Apple silicon** are not supported (the image is `linux/amd64`).
- **Paths A and B setup steps** (Part 2) were replayed once on a fresh App Build Environment started on a Linux host with KVM; they were not replayed on a Windows host, and not on a plain Ubuntu machine.
- **Builds are not bit-for-bit reproducible**, though all tool versions are pinned to exact
  versions and checksums.
- **Licence:** MIT (file `LICENSE`). The SDK and every tool the image downloads keep their own licences; the builder image contains them and is not covered by this licence.

---

## 11. What is in this folder

| File | Purpose |
|---|---|
| `README.md` | This guide. |
| `ctrlx-build.sh` | The launcher for Paths A and B: detects language, asks for architecture, builds the image on first use, runs the container. |
| `Dockerfile` | The builder image definition (needs `container-build.sh` next to it). |
| `container-build.sh` | The script that runs inside the container and does the build. |
| `Dockerfile.single` | The same image in **one file** (the script is embedded). Generated. Path C. |
| `Dockerfile.norecipe` | Standalone project-script-only variant; requires `build-snap-<arch>.sh`, with no built-in recipes or `--recipe` option. |
| `make-single-dockerfile.sh` | Regenerates `Dockerfile.single` from `Dockerfile` and `container-build.sh`; `--check` verifies it. For maintainers. |
| `ctrlx-probe.sh` | Read-only check of a machine (resources, user namespaces, network, existing Docker). Changes nothing. |
| `test-samples.sh` | Builds a folder of sample projects (for maintainers). |
| `ctrlx-run.sh` | Maintainer runner: `doctor`, `image`, `build`, `test`, `test-all`, `record-image`, `check-ownership`, `image-timing`. By default it uses the current account's rootless Docker (no sudo). With `CTRLX_BUILD_USER=<account>` it runs everything through `sudo -u <account>` for a machine where another account owns the Docker daemon. `./ctrlx-run.sh doctor` is a quick health check of the Docker setup. |
| `LICENSE` | MIT licence. |
| `.gitattributes`, `.gitignore` | Keep LF line endings; keep logs, snaps and probe reports out of git. |

`Dockerfile` and `Dockerfile.single` produce the same tools. The image from `Dockerfile.single`
is a **different build** (different image ID, tag prefix `single-`); the sample builds were run on
the image from `Dockerfile` only.
