#!/usr/bin/env bash
set -o errexit -o nounset -o pipefail; shopt -s nullglob
btrfs_path='/var/socker' && cgroups='cpu,cpuacct,memory';
[[ $# -gt 0 ]] && while [ "${1:0:2}" == '--' ]; do OPTION=${1:2}; [[ $OPTION =~ = ]] && declare "socker_${OPTION/=*/}=${OPTION/*=/}" || declare "socker_${OPTION}=x"; shift; done

function socker_check() {
	btrfs subvolume list "$btrfs_path" | grep -qw "$1" && echo 0 || echo 1
}

function socker_init() { #HELP Create an image from a directory:\nsocker init <directory>
	uuid="img_$(shuf -i 42002-42254 -n 1)"
	if [[ -d "$1" ]]; then
		[[ "$(socker_check "$uuid")" == 0 ]] && socker_run "$@"
		btrfs subvolume create "$btrfs_path/$uuid" > /dev/null
		cp -rf --reflink=auto "$1"/* "$btrfs_path/$uuid" > /dev/null
		[[ ! -f "$btrfs_path/$uuid"/img.source ]] && echo "$1" > "$btrfs_path/$uuid"/img.source
		echo "Created: $uuid"
	else
		echo "No directory named '$1' exists"
	fi
}

function socker_pull() { #HELP Pull an image from Docker Hub:\nsocker pull <name> <tag>
	token="$(curl -sL -o /dev/null -D- -H 'X-Docker-Token: true' "https://index.docker.io/v1/repositories/$1/images" | tr -d '\r' | awk -F ': *' '$1 == "X-Docker-Token" { print $2 }')"
	registry='https://registry-1.docker.io/v1'
	id="$(curl -sL -H "Authorization: Token $token" "$registry/repositories/$1/tags/$2" | sed 's/"//g')"
	[[ "${#id}" -ne 64 ]] && echo "No image named '$1:$2' exists" && exit 1
	ancestry="$(curl -sL -H "Authorization: Token $token" "$registry/images/$id/ancestry")"
	IFS=',' && ancestry=(${ancestry//[\[\] \"]/}) && IFS=' \n\t'; tmp_uuid="$(uuidgen)" && mkdir /tmp/"$tmp_uuid"
	for id in "${ancestry[@]}"; do
		curl -#L -H "Authorization: Token $token" "$registry/images/$id/layer" -o /tmp/"$tmp_uuid"/layer.tar
		tar xf /tmp/"$tmp_uuid"/layer.tar -C /tmp/"$tmp_uuid" && rm /tmp/"$tmp_uuid"/layer.tar
	done
	echo "$1:$2" > /tmp/"$tmp_uuid"/img.source
	socker_init /tmp/"$tmp_uuid" && rm -rf /tmp/"$tmp_uuid"
}

function socker_rm() { #HELP Delete an image or container:\nsocker rm <image_id or container_id>
	[[ "$(socker_check "$1")" == 1 ]] && echo "No container named '$1' exists" && exit 1
	btrfs subvolume delete "$btrfs_path/$1" > /dev/null
	cgdelete -g "$cgroups:/$1" &> /dev/null || true
	echo "Removed: $1"
}

function socker_images() { #HELP List images:\nsocker images
	echo -e "IMAGE_ID\t\tSOURCE"
	for img in "$btrfs_path"/img_*; do
		img=$(basename "$img")
		echo -e "$img\t\t$(cat "$btrfs_path/$img/img.source")"
	done
}

function socker_ps() { #HELP List containers:\nsocker ps
	echo -e "CONTAINER_ID\t\tCOMMAND"
	for ps in "$btrfs_path"/ps_*; do
		ps=$(basename "$ps")
		echo -e "$ps\t\t$(cat "$btrfs_path/$ps/$ps.cmd")"
	done
}

function socker_run() { #HELP Create a container:\nsocker run <image_id> <command>
	uuid="ps_$(shuf -i 42002-42254 -n 1)"
	[[ "$(socker_check "$1")" == 1 ]] && echo "No image named '$1' exists" && exit 1
	[[ "$(socker_check "$uuid")" == 0 ]] && echo "UUID conflict, retrying..." && socker_run "$@" && return
	cmd="${@:2}" && ip="$(echo "${uuid: -3}" | sed 's/0//g')" && mac="${uuid: -3:1}:${uuid: -2}"
	ip link add dev veth0_"$uuid" type veth peer name veth1_"$uuid"
	ip link set dev veth0_"$uuid" up
	ip link set veth0_"$uuid" master bridge0
	ip netns add netns_"$uuid"
	ip link set veth1_"$uuid" netns netns_"$uuid"
	ip netns exec netns_"$uuid" ip link set dev lo up
	ip netns exec netns_"$uuid" ip link set veth1_"$uuid" address 02:42:ac:11:00"$mac"
	ip netns exec netns_"$uuid" ip addr add 10.0.0."$ip"/24 dev veth1_"$uuid"
	ip netns exec netns_"$uuid" ip link set dev veth1_"$uuid" up
	ip netns exec netns_"$uuid" ip route add default via 10.0.0.1
	btrfs subvolume snapshot "$btrfs_path/$1" "$btrfs_path/$uuid" > /dev/null
	echo 'nameserver 8.8.8.8' > "$btrfs_path/$uuid"/etc/resolv.conf
	echo "$cmd" > "$btrfs_path/$uuid/$uuid.cmd"
	cgcreate -g "$cgroups:/$uuid"
	: "${socker_CPU_SHARE:=512}" && cgset -r cpu.shares="$socker_CPU_SHARE" "$uuid"
	: "${socker_MEM_LIMIT:=512}" && cgset -r memory.limit_in_bytes="$((socker_MEM_LIMIT * 1000000))" "$uuid"
	cgexec -g "$cgroups:$uuid" \
		ip netns exec netns_"$uuid" \
		unshare -fmuip --mount-proc \
		chroot "$btrfs_path/$uuid" \
		/bin/sh -c "/bin/mount -t proc proc /proc && $cmd" \
		2>&1 | tee "$btrfs_path/$uuid/$uuid.log" || true
	ip link del dev veth0_"$uuid"
	ip netns del netns_"$uuid"
}

function socker_exec() { #HELP Execute a command in a running container:\nsocker exec <container_id> <command>
	[[ "$(socker_check "$1")" == 1 ]] && echo "No container named '$1' exists" && exit 1
	cid="$(ps o ppid,pid | grep "^$(ps o pid,cmd | grep -E "^\ *[0-9]+ unshare.*$1" | awk '{print $1}')" | awk '{print $2}')"
	[[ ! "$cid" =~ ^\ *[0-9]+$ ]] && echo "Container '$1' exists but is not running" && exit 1
	nsenter -t "$cid" -m -u -i -n -p chroot "$btrfs_path/$1" "${@:2}"
}

function socker_logs() { #HELP View logs from a container:\nsocker logs <container_id>
	[[ "$(socker_check "$1")" == 1 ]] && echo "No container named '$1' exists" && exit 1
	cat "$btrfs_path/$1/$1.log"
}

function socker_commit() { #HELP Commit a container to an image:\nsocker commit <container_id> <image_id>
	[[ "$(socker_check "$1")" == 1 ]] && echo "No container named '$1' exists" && exit 1
	[[ "$(socker_check "$2")" == 1 ]] && echo "No image named '$2' exists" && exit 1
	socker_rm "$2" && btrfs subvolume snapshot "$btrfs_path/$1" "$btrfs_path/$2" > /dev/null
	echo "Created: $2"
}

function socker_help() { #HELP Display this message:\nsocker help
	sed -n "s/^.*#HELP\\s//p;" < "$1" | sed "s/\\\\n/\n\t/g;s/$/\n/;s!socker!${1/!/\\!}!g"
}

[[ -z "${1-}" ]] && socker_help "$0"
case $1 in
	pull|init|rm|images|ps|run|exec|logs|commit) socker_"$1" "${@:2}" ;;
	*) socker_help "$0" ;;
