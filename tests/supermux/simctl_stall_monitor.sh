#!/bin/zsh
# simctl_stall_monitor.sh - detect, and capture evidence of, slow `simctl` launches.
#
# What it detects: dyld4's RemoteNotificationResponder sends a synchronous mach
# message to every image-load observer port registered on a new process
# (task_dyld_process_info_notify_register, used through CoreSymbolication by
# sample, spindump/SampleAnalysis, ReportCrash, Instruments) and waits for the
# reply with no timeout. A busy or wedged observer then keeps every new process
# it attaches to in _dyld_start before main. On 2026-10-03 this made every
# `simctl` launch take 4-5 s, then 20-22 s, while ls and xcrun stayed fast.
#
# Each round runs `$(xcrun --find simctl) help` in the background and times it
# with zsh's own clock (no process launch per tick). When it runs longer than
# THRESHOLD seconds, it captures while the probe is stalled: a `sample` of the
# probe and its children (Xcode 27's simctl is a bash wrapper that execs the
# real simctl), the processes that could be the observer, and the full `ps`.
# It then waits up to 120 s for the probe and records the total.
#
# Log: OUT/rounds.tsv, one line per round: timestamp, seconds, stalled (yes|no),
# capture dir (or -). It never kills anything but its own probe. No sudo.
# To name the observer (needs root): `sudo lsmp -p <stalled simctl pid>` lists
# who holds the ports dyld is waiting on.
#
# Usage: simctl_stall_monitor.sh [--once] [--interval SECONDS] [--threshold SECONDS] [--out DIR]
#   --once        one round; exit 0 when healthy, 3 when stalled
#   --interval    seconds between rounds (default 60)
#   --threshold   seconds before a probe counts as stalled (default 2)
#   --out         output dir (default ~/Library/Logs/supermux-simctl-stall)

emulate -L zsh
zmodload zsh/datetime
setopt no_monitor no_notify

once=0 interval=60 threshold=2 bound=120
out="$HOME/Library/Logs/supermux-simctl-stall"
observers='spindump|sysdiagnose|ReportCrash|tailspin|symptomsd-diag|coresymbolicationd|[/ ]sample |lldb|debugserver|Instruments|DTServiceHub|CoreSimulator|SimulatorTrampoline|cmux-simulator-worker|cmux DEV'

while (( $# )); do
  case "$1" in
    --once) once=1 ;;
    --interval) interval="${2:?}"; shift ;;
    --threshold) threshold="${2:?}"; shift ;;
    --out) out="${2:?}"; shift ;;
    *) sed -n '/^# Usage:/,/^#   --out/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done

simctl="$(xcrun --find simctl)" || { print -u2 "cannot resolve simctl"; exit 2 }
mkdir -p "$out" || exit 2

# The probe and its descendants (the wrapper execs the real simctl or runs helpers first).
probe_tree() {
  local -a pids=("$1") kids
  kids=(${(f)"$(pgrep -P "$1")"})
  local kid
  for kid in $kids; do pids+=($(probe_tree "$kid")); done
  print -l $pids
}

capture() {
  local pid=$1 dir=$2 p
  mkdir -p "$dir"
  {
    print "# probe $pid and its children while stalled"
    for p in $(probe_tree "$pid"); do ps -o pid=,ppid=,etime=,stat=,command= -p "$p"; done
    print "\n# processes that may hold dyld image-load observer ports"
    ps -axo pid,ppid,lstart,etime,stat,%cpu,command | grep -E "PID|$observers" | grep -v grep
  } > "$dir/ps-observers.txt" 2>&1
  ps -axo pid,ppid,lstart,etime,stat,%cpu,command > "$dir/ps-full.txt" 2>&1
  # In the background, so the capture does not lengthen the measured stall.
  for p in $(probe_tree "$pid"); do sample "$p" 3 -file "$dir/sample-$p.txt" >/dev/null 2>&1 & done
}

round() {
  local start=$EPOCHREALTIME stalled=no dir=- elapsed pid
  "$simctl" help >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( EPOCHREALTIME - start ))
    if [[ $stalled == no ]] && (( elapsed >= threshold )); then
      stalled=yes
      dir="$out/stall-$(strftime %Y%m%d-%H%M%S $EPOCHSECONDS)-$pid"
      capture "$pid" "$dir"
    fi
    if (( elapsed >= bound )); then
      local -a tree=(${(f)"$(probe_tree "$pid")"})
      for p in ${(Oa)tree}; do kill -9 "$p" 2>/dev/null; done
      print -u2 "probe still running after ${bound}s; stopped it"
      break
    fi
    sleep 0.05
  done
  wait "$pid" 2>/dev/null
  elapsed=$(printf '%.3f' $(( EPOCHREALTIME - start )))
  (( elapsed >= threshold )) && stalled=yes
  wait 2>/dev/null # the background samples
  [[ $dir != - ]] && print "simctl=$simctl seconds=$elapsed" > "$dir/summary.txt"
  printf '%s\t%s\t%s\t%s\n' "$(strftime %Y-%m-%dT%H:%M:%S%z $EPOCHSECONDS)" "$elapsed" "$stalled" "$dir" >> "$out/rounds.tsv"
  print -r -- "simctl help: ${elapsed}s stalled=$stalled capture=$dir"
  [[ $stalled == no ]]
}

if (( once )); then
  round && exit 0
  exit 3
fi
while true; do
  round
  sleep "$interval"
done
