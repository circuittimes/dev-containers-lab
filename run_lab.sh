#!/bin/bash
# Dev container lab. Runs every test the article reports and prints a transcript.
# Each test asserts its expected result. The script exits nonzero as soon as one does not hold.
#
# The six project folders are copied into a new private folder with a random name, and every
# container is started from there. The random private path helps distinguish this run's
# containers from containers using other project folders. It is not an ownership credential.
#
# Two settings exist for the safety tests only:
#   LAB_RUN_DIR  use this empty folder as the private run folder
#   LAB_CLI      run this program in place of the devcontainer command
cd "$(dirname "$0")" || exit 1
. ./env.sh || exit 1
SRC="$PWD"
set -o pipefail
IMAGE=mcr.microsoft.com/devcontainers/base:alpine
LAB="demo ports steps built feat-local feat-apt"
CLI="${LAB_CLI:-devcontainer}"
MINE=""     # full IDs that passed this run's container identity checks
SAFE=""     # full ID of the unrelated container that T13 starts
PENDING=""  # the folder devcontainer up is running for right now, if any
UNVERIFIED="" # a folder for which the CLI returned but no checked container ID was recorded
STOP=""     # set by a signal

say(){ stopcheck; echo; echo "=== $1"; }
fail(){ echo "LAB FAILED: $1"; if [ -n "$RUN" ]; then echo "The run folder was kept for inspection: $RUN"; fi; exit 1; }
stopcheck(){ if [ -n "$STOP" ]; then echo "LAB STOPPED: the run was interrupted"; exit 130; fi; }
label(){ docker inspect --format "{{index .Config.Labels \"$2\"}}" "$1"; }
has(){ case " $(echo $1) " in *" $2 "*) return 0;; esac; return 1; }

# Cleanup removes only the IDs recorded in MINE and SAFE. It never searches by label or name.
# It then checks that each one is gone. If not, it says so and the script exits with status 3.
cleanup(){
  local id now left=""
  if [ -n "$PENDING" ]; then
    echo "POSSIBLE LEFTOVER: the run was interrupted while devcontainer up was running for the $PENDING folder."
    echo "This script has no checked ID for a container there, so it removed nothing for that folder."
    echo "Inspect with: docker ps -a --filter label=devcontainer.local_folder=$RUN/$PENDING"
    PENDING=""
  fi
  if [ -n "$UNVERIFIED" ]; then
    echo "POSSIBLE LEFTOVER: the CLI returned for the $UNVERIFIED folder, but this script did not record a checked container ID for it."
    echo "It removed nothing for that folder."
    echo "Inspect with: docker ps -a --filter label=devcontainer.local_folder=$RUN/$UNVERIFIED"
    UNVERIFIED=""
  fi
  if [ -z "$MINE$SAFE" ]; then return; fi
  docker rm -f $MINE $SAFE >/dev/null 2>&1
  now="$(docker ps -aq --no-trunc)" || { echo "CLEANUP FAILED: could not check whether these containers are gone: $MINE $SAFE"; exit 3; }
  for id in $MINE $SAFE; do if has "$now" "$id"; then left="$left $id"; fi; done
  if [ -n "$left" ]; then echo "CLEANUP FAILED: these containers from this run are still present:$left"; exit 3; fi
  MINE=""; SAFE=""
}
# A signal only sets a flag. The script stops at the next safe point.
trap 'STOP=1' INT TERM
trap cleanup EXIT

# Containers that carry the label of one run folder. The status of docker ps is always checked.
folder_ids(){ docker ps -aq --no-trunc --filter "label=devcontainer.local_folder=$RUN/$1"; }

# Private run folder.
if [ -n "$LAB_RUN_DIR" ]; then RUN="$LAB_RUN_DIR"; else RUN="$(mktemp -d /tmp/dclab.XXXXXXXXXX)" || fail "could not create a private run folder"; fi
[ -d "$RUN" ] || fail "the run folder does not exist"
for d in $LAB; do
  if [ ! -d "$RUN/$d" ]; then cp -r "$SRC/$d" "$RUN/$d" || fail "could not copy the $d project"; fi
  old="$(folder_ids "$d")" || fail "could not list containers, nothing was started"
  if [ -n "$old" ]; then fail "a container for the $d folder already exists, nothing was started or removed"; fi
done

# Start a dev container. Record its ID only when the container passes these identity checks:
#   1. just before the call, every container carrying the folder label is already recorded in MINE
#   2. the CLI reports success and returns an ID
#   3. that container carries this run folder's label and this run's config file label
start(){
  local out id before lf cf rc
  before="$(folder_ids "$1")" || fail "could not list containers before starting $1"
  for id in $before; do
    if ! has "$MINE" "$id"; then fail "a container not recorded by this run is using the $1 folder, nothing was removed for it"; fi
  done
  PENDING="$1"
  out="$("$CLI" up --workspace-folder "$RUN/$1" 2>/dev/null)"; rc=$?
  if [ -n "$STOP" ]; then echo "LAB STOPPED: interrupted while devcontainer up was running for the $1 folder"; exit 130; fi
  PENDING=""; UNVERIFIED="$1"
  if [ $rc -ne 0 ]; then fail "devcontainer up failed for $1"; fi
  LAST="$(echo "$out" | tail -1)"
  id="$(echo "$LAST" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print(d.get('containerId','') if d.get('outcome')=='success' else '')")" || fail "could not read the result for $1"
  if [ -z "$id" ]; then fail "devcontainer up did not report success for $1"; fi
  lf="$(label "$id" devcontainer.local_folder)" || fail "could not inspect the container for $1"
  cf="$(label "$id" devcontainer.config_file)" || fail "could not inspect the container for $1"
  if [ "$lf" != "$RUN/$1" ] || [ "$cf" != "$RUN/$1/.devcontainer/devcontainer.json" ]; then
    fail "the CLI returned a container for $1 that did not pass this run's identity checks, nothing was removed for it"
  fi
  if ! has "$MINE" "$id"; then MINE="$MINE $id"; fi
  CID="$id"; UNVERIFIED=""
  stopcheck
}
up(){
  local s=$(date +%s.%N)
  start "$1"
  echo "$LAST" | python3 -c "import json,sys;d=json.loads(sys.stdin.read());print('outcome:',d.get('outcome'),'| remoteUser:',d.get('remoteUser'),'| remoteWorkspaceFolder:',d.get('remoteWorkspaceFolder'))" || fail "could not print the result for $1"
  echo "seconds: $(python3 -c "print(round($(date +%s.%N)-$s))")"
}
# Run a command in a dev container, print what it printed, and keep it in OUT for the assertion.
ex(){ local f=$1; shift; OUT="$("$CLI" exec --workspace-folder "$RUN/$f" "$@" 2>/dev/null)" || fail "command failed inside the $f container"; if [ -n "$OUT" ]; then echo "$OUT"; fi; stopcheck; }
# Assert that OUT is exactly the expected text, or that it has an exact line.
same(){ if [ "$OUT" != "$1" ]; then fail "$2"; fi; }
line(){ echo "$OUT" | grep -Fxq "$1" || fail "$2"; }

say "T0 versions"
command -v python3 >/dev/null || fail "python3 was not found, nothing was started"
"$CLI" --version || fail "the devcontainer program was not found"
docker --version || fail "the docker program was not found"
uname -sr | cut -d- -f1; echo "host user: $(id -un) uid $(id -u)"

say "T1 up from an image"; up demo; DEMO="$CID"

say "T2 inside the container"
ex demo sh -c 'echo "user: $(id -un) uid $(id -u)"; echo "folder: $(pwd)"; echo "files: $(ls)"; echo "DEMO_MODE: $DEMO_MODE"; echo "post-create file: $(cat /tmp/post-create.txt)"; head -1 /etc/os-release; git --version'
line "user: vscode uid $(id -u)" "T2: the user is not vscode with the host user's ID"
line "folder: /workspaces/demo" "T2: the working folder is not /workspaces/demo"
line "DEMO_MODE: inside-container" "T2: the variable from the file is not set"
line "post-create file: created" "T2: the post-create file is missing or wrong"

say "T3 files are shared both ways"
echo "edited on the host" > "$RUN/demo/note.txt"; ex demo cat note.txt
same "edited on the host" "T3: the container did not see the host's edit"
ex demo sh -c 'echo "written in the container" > from-container.txt'
OUT="$(cat "$RUN/demo/from-container.txt")" || fail "T3: the file written in the container is not on the host"
echo "$OUT"; same "written in the container" "T3: the host did not see the container's file"
OUT="$(ls -n "$RUN/demo/from-container.txt" | awk '{print $3}')"; echo "owner uid on host: $OUT"
same "$(id -u)" "T3: the file is not owned by the host user"

say "T4 forwardPorts and the CLI"
OUT="$(docker port "$DEMO")" || fail "docker port failed for demo"
stopcheck
echo "docker port output: [$OUT]"
same "" "T4: a port was published although only forwardPorts was set"

say "T5 appPort and the CLI"; start ports
OUT="$(docker port "$CID" | head -1)" || fail "docker port failed for ports"
echo "docker port output: [$OUT]"
same "8000/tcp -> 127.0.0.1:8000" "T5: the published port is not 8000 on 127.0.0.1"

say "T6 lifecycle order, first create"; start steps; STEPS="$CID"; ex steps cat /tmp/order.txt
same "onCreateCommand
updateContentCommand
postCreateCommand
postStartCommand
postAttachCommand" "T6: the first-create order is not the expected five commands"

say "T7 lifecycle order, after stop and second up"
docker stop "$STEPS" >/dev/null || fail "could not stop the steps container"
stopcheck
start steps; ex steps cat /tmp/order.txt
same "onCreateCommand
updateContentCommand
postCreateCommand
postStartCommand
postAttachCommand
postStartCommand
postAttachCommand" "T7: the order after a second start is not the expected seven lines"

say "T8 build from a Dockerfile"; up built; ex built cat /etc/built-marker.txt
same "baked into the image at build time" "T8: the marker from the Dockerfile is missing"

say "T9 local Feature"; up feat-local; ex feat-local cat /usr/local/share/hello-feature.txt
same "hello from a Feature" "T9: the local Feature did not install"
OUT="$(ls "$RUN/feat-local/.devcontainer" | grep lock)" || fail "T9: no lockfile was written"
echo "lockfile written: $OUT"
same "devcontainer-lock.json" "T9: the lockfile has an unexpected name"

# T10 is the one test that must fail, and for the expected reason.
say "T10 apt-based Feature on an Alpine image"
PENDING="feat-apt"
OUT="$("$CLI" up --workspace-folder "$RUN/feat-apt" 2>&1)"; RC=$?
if [ -n "$STOP" ]; then echo "LAB STOPPED: interrupted while devcontainer up was running for the feat-apt folder"; exit 130; fi
PENDING=""; UNVERIFIED="feat-apt"
if [ $RC -eq 0 ]; then fail "T10: the apt-based Feature was expected to fail and did not"; fi
echo "$OUT" | grep -q "apt-get: command not found" || fail "T10: the Feature failed for a different reason than apt-get"
echo "$OUT" | grep -E "apt-get: command not found|failed to install" | sed -E 's/^(#[0-9]+ )?[0-9.]+ //' | sort -u | cut -c1-96
R="$(echo "$OUT" | grep '"outcome"' | tail -1 | python3 -c "import json,sys;print(json.loads(sys.stdin.read()).get('outcome'))")" || fail "T10: could not read the result"
if [ "$R" != "error" ]; then fail "T10: reported $R, expected error"; fi
echo "outcome: $R"
OUT="$(folder_ids feat-apt)" || fail "T10: could not check containers after the failed Feature build"
same "" "T10: the failed build left a container behind"
UNVERIFIED=""

say "T11 plain docker run for comparison"
OUT="$(docker run --rm -v "$RUN/demo":/src -w /src $IMAGE sh -c 'echo "user: $(id -un)"; echo "folder: $(pwd)"; echo "DEMO_MODE: [$DEMO_MODE]"; ls /tmp/post-create.txt 2>&1 | sed "s/^ls: //"')" || fail "T11: plain docker run failed"
stopcheck
echo "$OUT"
line "user: root" "T11: plain docker run did not use root"
line "DEMO_MODE: []" "T11: plain docker run had the variable set"
line "cannot access '/tmp/post-create.txt': No such file or directory" "T11: the post-create file exists in a plain container"

say "T12 labels the CLI puts on the container"
OUT="$(docker inspect "$DEMO" --format '{{range $k,$v := .Config.Labels}}{{println $k}}{{end}}' | grep '^devcontainer\.')" || fail "T12: the CLI labels were not found"
echo "$OUT"
same "devcontainer.config_file
devcontainer.local_folder
devcontainer.metadata" "T12: the CLI labels are not the expected three"

say "T13 remove only this run's containers, keep the files"
SAFE="$(docker run -d --label devcontainer.local_folder=/tmp/not-this-lab $IMAGE sleep 600)" || fail "T13: could not start the unrelated container"
stopcheck
echo "unrelated container created: yes"
COUNT="$(echo $MINE | wc -w)"
echo "lab containers found: $COUNT"
if [ "$COUNT" -ne 5 ]; then fail "T13: expected five lab containers, found $COUNT"; fi
docker rm -f $MINE >/dev/null || fail "T13: could not remove this run's containers"
NOW="$(docker ps -aq --no-trunc)" || fail "T13: could not check whether this run's containers are gone"
stopcheck
LEFT=0; for id in $MINE; do if has "$NOW" "$id"; then LEFT=$((LEFT + 1)); fi; done
echo "lab containers left: $LEFT"
if [ "$LEFT" -ne 0 ]; then fail "T13: some of this run's containers are still present"; fi
MINE=""
if has "$NOW" "$SAFE"; then STILL=1; else STILL=0; fi
echo "unrelated container still present: $STILL"
if [ "$STILL" -ne 1 ]; then fail "T13: the unrelated container was removed"; fi
OUT="$(ls "$RUN/demo" | tr '\n' ' ' | sed 's/ $//')"
echo "project files left: $OUT"
same "from-container.txt hello.py note.txt" "T13: the project files are not all still there"
stopcheck
# A complete run removes the private folder it made. A failed run keeps it for inspection.
if [ -z "$LAB_RUN_DIR" ]; then rm -r "$RUN" || fail "could not remove the private run folder"; fi
# A signal that arrived during that last step still ends the run with status 130.
stopcheck
