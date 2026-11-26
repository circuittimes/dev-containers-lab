#!/bin/bash
# Safety tests for run_lab.sh. Usage: bash safety_tests.sh [test name ...]   (no name runs all six)
# Each test uses its own private run folder, asserts its expected result and prints RESULT: pass,
# or stops with an ERROR line and a nonzero exit status.
cd "$(dirname "$0")" || exit 1
. ./env.sh || exit 1
IMAGE=mcr.microsoft.com/devcontainers/base:alpine
OTHER=""; ORPHANS=""; TMP=""
# Remove the given container IDs and verify that each one is gone.
gone(){ local id all; docker rm -f $1 >/dev/null || return 1; all="$(docker ps -aq --no-trunc)" || return 1; for id in $1; do if echo "$all" | grep -Fxq "$id"; then return 1; fi; done; return 0; }
# On exit, remove whatever test containers are still recorded. If that cannot be verified, say so and exit 3.
finish(){ local s=$?; if [ -n "$OTHER$ORPHANS" ]; then gone "$OTHER $ORPHANS" || { echo "TEST CLEANUP FAILED: these test containers may still be present: $OTHER $ORPHANS"; s=3; }; fi; if [ -n "$TMP" ]; then rm -r "$TMP"; fi; exit $s; }
trap finish EXIT
trap 'exit 130' INT TERM
err(){ echo "ERROR: $1"; exit 1; }
newrun(){ RUN="$(mktemp -d /tmp/dclab.XXXXXXXXXX)" || err "could not create a run folder"; OTHER=""; }
other(){ OTHER="$(docker run -d --label "devcontainer.local_folder=$RUN/$1" $IMAGE sleep 900)" || err "could not start the other container"; }
# Every inventory is captured with its exit status checked, so a Docker error is never read as "no containers".
ids_for(){ IDS="$(docker ps -aq --no-trunc --filter "label=devcontainer.local_folder=$RUN/$1")" || err "could not inspect containers for $1"; }
alive(){ local all; all="$(docker ps -aq --no-trunc)" || err "could not list containers"; echo "$all" | grep -Fxq "$1"; }
survives(){ alive "$OTHER" || err "the other process's container was removed"; echo "other process's container still present: 1"; gone "$OTHER" || err "could not remove the other test container, or it still exists after removal"; OTHER=""; }
mine_left(){ local n=0 d id; for d in demo ports steps built feat-local feat-apt; do ids_for $d; for id in $IDS; do if [ "$id" != "$OTHER" ]; then n=$((n + 1)); fi; done; done; LEFTN=$n; }

# 1. A container already carries the label of a lab folder before the lab starts.
t_preexisting(){
  newrun; other feat-apt
  LAB_RUN_DIR="$RUN" bash run_lab.sh > "$RUN/transcript.txt" 2>&1; S=$?
  echo "lab run exit status: $S"; [ $S -eq 1 ] || err "expected exit status 1"
  grep "^LAB FAILED: a container for the feat-apt folder already exists" "$RUN/transcript.txt" || err "the lab did not refuse to start"
  echo "tests started before the lab stopped: $(grep -c '^=== T' "$RUN/transcript.txt")"
  survives
}
# 2. Another process creates a container with a lab folder's label while the lab runs, after T10.
t_concurrent(){
  newrun
  LAB_RUN_DIR="$RUN" bash run_lab.sh > "$RUN/transcript.txt" 2>&1 & P=$!
  for i in $(seq 1 900); do grep -q "^=== T11" "$RUN/transcript.txt" 2>/dev/null && break; sleep 0.2; done
  other feat-apt
  kill -0 $P 2>/dev/null || err "the lab had already finished, the test proves nothing"
  echo "other container created while the lab was still running: yes"
  wait $P; S=$?; echo "lab run exit status: $S"; [ $S -eq 0 ] || err "expected exit status 0"
  grep -A5 "^=== T13" "$RUN/transcript.txt" | tail -5
  survives
}
# 3. The CLI is handed another process's container that carries only the folder label, and reports
#    success for it. A wrapper around the CLI creates that container after the lab's own check and
#    before the CLI runs. This does not cover a foreign container that carries both of the CLI's labels:
#    the lab cannot tell that one from its own.
t_adopted(){
  newrun; TMP="$(mktemp -d)" || err "no temp folder"
  printf '#!/bin/bash\nif [ "$1" = up ] && [ "$3" = "%s/ports" ]; then docker run -d --label "devcontainer.local_folder=%s/ports" %s sleep 900 > "%s/other.id" || exit 9; fi\nexec devcontainer "$@"\n' "$RUN" "$RUN" "$IMAGE" "$TMP" > "$TMP/cli"; chmod +x "$TMP/cli"
  LAB_RUN_DIR="$RUN" LAB_CLI="$TMP/cli" bash run_lab.sh > "$RUN/transcript.txt" 2>&1; S=$?
  OTHER="$(cat "$TMP/other.id" 2>/dev/null)"; [ -n "$OTHER" ] || err "the wrapper did not create the other container"
  echo "lab run exit status: $S"; [ $S -eq 1 ] || err "expected exit status 1"
  grep "^LAB FAILED: the CLI returned a container for ports that did not pass this run's identity checks" "$RUN/transcript.txt" || err "the lab did not reject the container the CLI returned"
  mine_left; echo "containers of this run left: $LEFTN"; [ "$LEFTN" -eq 0 ] || err "the lab left its own containers"
  survives; rm -r "$TMP"; TMP=""
}
# 4. One expected-success test is broken on purpose.
t_broken(){
  newrun; cp -r built "$RUN/built" || err "copy failed"; echo "RUN exit 1" >> "$RUN/built/.devcontainer/Dockerfile"
  LAB_RUN_DIR="$RUN" bash run_lab.sh > "$RUN/transcript.txt" 2>&1; S=$?
  echo "lab run exit status: $S"; [ $S -eq 1 ] || err "expected exit status 1"
  grep "^LAB FAILED: devcontainer up failed for built" "$RUN/transcript.txt" || err "the lab did not report the broken test"
  echo "last test started: $(grep '^=== T' "$RUN/transcript.txt" | tail -1)"
  mine_left; echo "containers of this run left: $LEFTN"; [ "$LEFTN" -eq 0 ] || err "cleanup did not run"
}
# 5. The lab and the CLI are killed after Docker first lists the ports container, while devcontainer up
#    is still running, and another process owns a container with the same folder label.
t_killed(){
  newrun; TMP="$(mktemp -d)" || err "no temp folder"
  printf '#!/bin/bash\nif [ "$1" = up ] && [ "$3" = "%s/ports" ]; then\n  touch "%s/cli-started"; devcontainer "$@" & C=$!\n  while kill -0 $C 2>/dev/null; do LISTED="$(docker ps -aq --filter "label=devcontainer.local_folder=%s/ports")" || { echo "Docker inventory failed while waiting for the ports container" >&2; touch "%s/inventory-failed"; exit 10; }; if [ -n "$LISTED" ]; then touch "%s/container-listed"; break; fi; sleep 0.05; done\n  wait $C; R=$?; touch "%s/cli-exited"; exit $R\nfi\nexec devcontainer "$@"\n' "$RUN" "$TMP" "$RUN" "$TMP" "$TMP" "$TMP" > "$TMP/cli"; chmod +x "$TMP/cli"
  LAB_RUN_DIR="$RUN" LAB_CLI="$TMP/cli" setsid bash run_lab.sh > "$RUN/transcript.txt" 2>&1 & P=$!
  for i in $(seq 1 1200); do [ -e "$TMP/container-listed" ] && break; [ -e "$TMP/cli-exited" ] && break; sleep 0.05; done
  [ -e "$TMP/inventory-failed" ] && err "Docker inventory failed while waiting for the ports container"
  [ -e "$TMP/cli-started" ] || err "the CLI was never started for the ports folder"
  [ -e "$TMP/container-listed" ] || err "the ports container was not visible in Docker while devcontainer up was running"
  [ -e "$TMP/cli-exited" ] && err "the CLI had already exited before the kill, the test proves nothing"
  other ports
  kill -TERM -- -$P || err "could not signal the lab"
  echo "kill sent after Docker first listed the ports container, while devcontainer up was still running: yes"
  wait $P; S=$?; echo "lab run exit status: $S"; [ $S -eq 130 ] || err "expected exit status 130"
  grep "^LAB STOPPED: interrupted while devcontainer up was running for the ports folder" "$RUN/transcript.txt" || err "the lab did not report the interruption"
  grep "^POSSIBLE LEFTOVER" "$RUN/transcript.txt" || err "the lab did not report the possible leftover"
  alive "$OTHER" || err "the other process's container was removed"
  ids_for ports; ORPHANS=""; for id in $IDS; do if [ "$id" != "$OTHER" ]; then ORPHANS="$ORPHANS $id"; fi; done
  echo "unverified containers the lab left for the ports folder, as designed: $(echo $ORPHANS | wc -w)"
  FOUND=0; for d in demo steps built feat-local feat-apt; do ids_for $d; FOUND=$((FOUND + $(echo $IDS | wc -w))); done
  echo "containers left for the folders the lab had finished starting: $FOUND"; [ $FOUND -eq 0 ] || err "the lab left containers it owned"
  survives
  if [ -n "$ORPHANS" ]; then gone "$ORPHANS" || err "could not remove the unverified container, or it still exists after removal"; echo "this test then removed the unverified container itself, and checked it is gone: yes"; ORPHANS=""; fi
  rm -r "$TMP"; TMP=""
}
# 6. Container removal is made to fail on purpose.
t_removal(){
  newrun; TMP="$(mktemp -d)" || err "no temp folder"; REAL="$(command -v docker)"
  printf '#!/bin/bash\nif [ "$1" = "rm" ]; then exit 1; fi\nexec %s "$@"\n' "$REAL" > "$TMP/docker"; chmod +x "$TMP/docker"
  LAB_RUN_DIR="$RUN" PATH="$TMP:$PATH" bash run_lab.sh > "$RUN/transcript.txt" 2>&1; S=$?
  echo "lab run exit status: $S"; [ $S -eq 3 ] || { err "expected exit status 3"; }
  L="$(grep "^CLEANUP FAILED: these containers from this run are still present:" "$RUN/transcript.txt")" || err "the lab did not report the cleanup failure"
  ORPHANS="$(echo "$L" | sed 's/.*still present://')"
  echo "CLEANUP FAILED reported, containers named: $(echo $ORPHANS | wc -w)"
  PATH="$(dirname "$REAL"):$PATH" gone "$ORPHANS" || err "could not remove the named containers, or they still exist after removal"; ORPHANS=""
  echo "this test then removed exactly the named containers, and checked they are gone: yes"
  rm -r "$TMP"; TMP=""
}
for t in ${@:-preexisting concurrent adopted broken killed removal}; do echo; echo "=== safety test: $t"; t_$t; rm -r "$RUN"; echo "RESULT: pass"; done
