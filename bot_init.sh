#!/bin/sh

usage()
{
	printf "Usage: $0 <motd message>\n" >&2
}

MOTD="${1:-Hello from BOT-X. Let's DDoS someone ;)}"
#[ -z "$1" ] && { usage; exit 1; }

cur_user=$(id -un)
need_packages="figlet git python3-venv"
mhddos_reqs="wget libcurl4 libssl-dev python3 python3-pip make cmake automake autoconf m4 build-essential git"

sudo -n -i <<EOF
exec 2>/dev/null

check_status()
{
	[ "\$?" -eq 0 ] &&
		printf "OK\n" ||
		{ printf "FAILED\n"; exit 1; }
}

# create usefule dirs
mkdir -p ~/.local/{src,bin,share}

# update repositories
printf "Updating repositiries... "
apt update -y >/dev/null ; check_status

# install necessary packages
printf "Installing packages... "
apt-get install -qq -y $need_packages $mhddos_reqs >/dev/null ; check_status

# install MHDDoS script
printf "Installing MHDDos script... "
( git clone https://github.com/MatrixTM/MHDDoS.git .local/src/MHDDoS &>/dev/null
	python3 -m venv .mhddos_pyvenv
	source .mhddos_pyvenv/bin/activate
	pip3 install -r .local/src/MHDDoS/requirements.txt &>/dev/null
	deactivate
	cat >.local/bin/MHDDoS <<EOF2
#!/bin/sh
. ~/.mhddos_pyvenv/bin/activate
cd ~/.local/src/MHDDoS; python3 start.py "\\\$@"
deactivate
EOF2
	chmod +x .local/bin/MHDDoS
) ; check_status

# enable ssh root login
printf "Enabling ssh root login... "
(
sed -ri 's/^(PermitRootLogin)\s+no/\1 prohibit-password/' /etc/ssh/sshd_config
systemctl reload sshd.service
) ; check_status

# delete automatically created user
[ "$cur_user" = "root" -o "$cur_user" = "0" ] || deluser --remove-home "${cur_user}"

printf "Making shell environment more pleasant... "
# make environment more pleasant
(
rm ~/{.bashrc,.profile}
mkdir -p ~/.local/src
git clone https://github.com/rednhot/dotfiles .local/src/dotfiles 
.local/src/dotfiles/install.sh >/dev/null
) ; check_status

# nice looking motd on login
figlet "$MOTD" | tee /etc/motd >/dev/null
EOF
