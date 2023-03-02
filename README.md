## gcloud-botnet ##

### Description ###

This is a script that aids in managing a botnet in the  *Google Cloud Platform*. It allows to manipulate botnets of variable sizes, and do such things as create/destroy botnet, or run some command on all or part of a botnet. 


Currently you can treat it as a kind of a wrapper around `gcloud` and `MHDDoS` scripts, because it's implemented in this usage in mind, but you can easily tune it to your personal needs.


Here's its usage help, pretty self-explanatory:
``` text
Usage: ./botcc.sh [options...]
	-a, --all                 Run action on each bot in the botnet.
	-n, --num <num>           Run action on num random bots.
	-b, --bot <botname>       Run action on specified bot.
	-B, --botnet <botnet>     Specify botnet to act on.
	-d, --delete              Delete specified bots.
	-c, --create              Create some bots.
	-r, -C, --command <cmd>   Command to run on each bot.
	--attack <Layer:attack>   Run this MHDDoS attack on bots
	--victim <victim_spec>    Victim specification, like in MHDDoS
	-l, --list                List bots in selected botnet.
	--async                   Launch things asynchronously.
	-t,--no-tty               Don't allocate pty device
	-u, --user <user>         Run command on bot under the user.
	-S, --ssh-key-file <file> Connect to bot with this ssh key file.
	-z, --zone <zone>         (With -c only) Create bots in this zone
	-Z, --zone-file <file>    (With -c only) Create bots in zones, specified in the file.

	-v, --verbose             Make output more verbose.
	-q, --quiet               Be more quiet.
```

**WARNING:** Currently, user needs to setup `google api`, so that `gcloud` command is authorized to do things on user's account, in other words `gcloud` is usable and doesn't need no more configuration. See **Google API docs**.

### Create botnet ###

Example:

``` shell
./botcc.sh -c -n 10 -B test --async -v -z europe-west4-c
```

This command will create a botnet of size **10** bots in the botnet named *test*, located in the google zone *europe-west4-c*, verbosely and asynchronously. `-z` or `-Z` flags are optional, and allows users to create bots in specific geographical zones.

**Hint:** Use `--async` flag, because it really speeds up things, and the time needed to create a botnet, for example, decreases drastically. **But** be aware that remote commands won't produce any output to the screen, because underlying `ssh` process exits immediately after starting a process on the remote end. It's a type of compromise, since otherwise in an alternative implementation, a lot of `ssh` processes will hang on the *C&C* host, waiting in the background and consuming lots of the system's resources. Redirect command's `stdout` to a file in order to capture it.

This is how this command works internally:

1. Create a bot.
2. Copy **bot init script**(`bot_init.sh` by default) to the bot.
3. Run that script.

Bot initialization script is highly my personal taste, but long story short, it will install [MHDDoS](https://github.com/MatrixTM/MHDDoS "MHDDoS") script on a bot.

### List botnet ###

``` shell
./botcc.sh --list --quiet --all --botnet test
```

This command will list all of the bots owned by botnet *test*. Without `--quiet` flag it will also show associated with each bot google **zone**, in which it was created.

User can also specify `-n` option instead of `--all`, to just show **n** random bots, for whatever reason.

### Destroy botnet ###

It's how a user would remove the whole botnet named *test*.
``` shell
./botcc.sh -d -a -B test --async
```

Note that `-n` option can be specified instead of `-a` to remove **n** random bots.

### Start a DDoS attack ###

To run an attack, one would need to specify both `--attack` and `--victim` options.

The `--attack` option's format is "LAYER:ATTACK", where layer specifies **OSI** layer of the attack, and **ATTACK** specifies the name of an attack, as listed in the [MHDDoS](https://github.com/MatrixTM/MHDDoS/ "MHDDoS") documentation.

Example *1*: **syn** flood attack using 5 random bots from the botnet *test*

``` shell
./botcc.sh -n 5 -B test --attack L4:syn --victim 127.0.0.1:80 --async -v
```

Example *2*: **get** flood attack, using all bots of the botnet *test*

``` shell
./botcc.sh -a -B test --attack L7:get --victim http://127.0.0.1:80/index.html --async -v
```

No proxies will be used. If something doesn't suit user's needs, he can change underlying run command, or add another handler for **LAYER**, as an example.

### Run arbitrary command(not necessary DDoS attack) ###

That's how you would print load average of each of the bots

``` shell
./botcc.sh -a -r 'printf "hello from host $(hostname). Here is my uptime: $(uptime)\n"' -B test 
```

As with previous options, `-n` or `-a` option can be used to select on which bots of a botnet to run the command.

### TODO ###

  * Add something like an `--init` option, that will do all of the neccessary preparations of the *google cloud api* in a semi-automatic way and guide a user through the installation, so that user no longer needs to preconfigure his environment and read *google docs* before running this script. So much tasty feature that's still lacking :(
  * Add support for more cloud hosting providers. Can be useful, since google is dropping packets with spoofed source `IP` address, which is a crucial property restricting from usage of most of the **amplification** ddos attacks.
