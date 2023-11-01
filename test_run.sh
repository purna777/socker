#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail

function socker_run_test() {
	./socker run "$1" "$2" > /dev/null
	ps="$(./socker ps | grep "$2" | awk '{print $1}')"
	logs="$(./socker logs "$ps")"
	if [[ "$logs" == *"$3"* ]]; then
		echo 0
	else
		echo 1
	fi
}

img="$(./socker init ~/base-image | awk '{print $2}')"
./socker images | grep -qw "$img"
[[ "$?" == 0 ]]

[[ "$(socker_run_test "$img" 'echo foo' 'foo')" == 0 ]]
[[ "$(socker_run_test "$img" 'uname' 'Linux')" == 0 ]]
[[ "$(socker_run_test "$img" 'cat /proc/self/stat' '3 (cat)')" == 0 ]]
[[ "$(socker_run_test "$img" 'ip addr' 'veth1_ps_')" == 0 ]]
[[ "$(socker_run_test "$img" 'ping -c 1 8.8.8.8' '0% packet loss')" == 0 ]]
[[ "$(socker_run_test "$img" 'ping -c 1 google.com' '0% packet loss')" == 0 ]]
