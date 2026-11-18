#!/usr/bin/env bash
# Local user-systemd fixture only; no lab VM, product or authenticated session.
set -euo pipefail
source_file=${1:?Pass LinuxDetached.ps1}
eval "$(awk '/^linux_worker_active\(\) \{/{p=1} p{print} p && /^}/{exit}' "$source_file")"
command systemctl --user show-environment >/dev/null
U="paeasy-review-$(id -u)-$(cat /proc/sys/kernel/random/uuid).service"
cleanup(){ command systemctl --user stop "$U" >/dev/null 2>&1 || true;command systemctl --user reset-failed "$U" >/dev/null 2>&1 || true; }
trap cleanup EXIT
systemctl(){ command systemctl --user "$@"; }
command systemd-run --user --quiet --unit="$U" --property=Type=oneshot --property=RemainAfterExit=yes /bin/bash -c '(exec 1>/dev/null 2>/dev/null 3>&- 4>&-; sleep 20) &'
main=$(command systemctl --user show "$U" -p MainPID --value)
[[ $main = 0 ]]
linux_worker_active || { echo 'FAIL surviving child treated as quiescent';exit 1; }
echo 'PASS actual user-systemd: MainPID=0 with surviving stream-closed child retains worker activity.'
systemctl(){ command systemctl --user "$@" | sed 's/^TasksCurrent=.*/TasksCurrent=0/'; }
linux_worker_active || { echo 'FAIL cgroup child ignored when accounting counter is stale zero';exit 1; }
echo 'PASS actual cgroup.procs prevents release even when TasksCurrent is forced stale zero.'
grep(){ return 2; }
linux_worker_active || { echo 'FAIL task-file IO error treated as empty';exit 1; }
unset -f grep
echo 'PASS task-file IO error remains uncertain even after readable precheck.'
systemctl(){ command systemctl --user "$@"; }
command systemctl --user kill --kill-whom=all --signal=TERM "$U"
for i in $(seq 1 30);do if ! linux_worker_active;then break;fi;sleep 0.1;done
if linux_worker_active;then echo 'FAIL empty cgroup treated as active indefinitely';exit 1;fi
echo 'PASS actual user-systemd: empty cgroup and terminal unit metadata permit quiescence.'
cleanup
U="paeasy-review-stop-$(id -u)-$(cat /proc/sys/kernel/random/uuid).service"
command systemd-run --user --quiet --unit="$U" --property=Type=oneshot --property=RemainAfterExit=yes --property=ExecStopPost='/bin/sleep 2' /bin/true
command systemctl --user stop --no-block "$U"
for i in $(seq 1 20);do control=$(command systemctl --user show "$U" -p ControlPID --value);[[ $control != 0 ]] && break;sleep 0.1;done
[[ $control != 0 ]]
linux_worker_active || { echo 'FAIL active stop-post process treated as quiescent';exit 1; }
echo 'PASS actual user-systemd: ControlPID/stop-post activity prevents early release.'
# Pure metadata contract for fail-closed unavailable/malformed observer replies.
systemctl(){ printf 'LoadState=loaded\nActiveState=active\nSubState=exited\nMainPID=invalid\nControlPID=0\nTasksCurrent=0\nControlGroup=\n'; }
linux_worker_active || { echo 'FAIL malformed identity treated as quiescent';exit 1; }
systemctl(){ printf 'LoadState=loaded\nActiveState=active\nSubState=exited\nMainPID=0\nControlPID=0\nTasksCurrent=0\nControlGroup=\n';return 1; }
linux_worker_active || { echo 'FAIL partial failed property query treated as complete';exit 1; }
systemctl(){ return 1; }
linux_worker_active || { echo 'FAIL failed query treated as quiescent';exit 1; }
echo 'PASS malformed or unavailable unit metadata is uncertainty, never exit proof. Production system-scope path remains NotTested.'
