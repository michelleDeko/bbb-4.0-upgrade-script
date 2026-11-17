# bbb-4.0-upgrade-script
Unofficial script to upgrade a BigBlueButton 3.0 server (Ubuntu 22.04) in place to 4.0 (Ubuntu 24.04).

> [!WARNING]
> This script is not official and not affiliated with the BigBlueButton project. There is no support for it: use it at your own risk.

The script also repairs what the release upgrade breaks, where the server has it:

- starts the local coturn again
- reinstalls the optional BigBlueButton packages of the 3.0 install
- rebuilds the Python environment of bbb-livekit-stt, if installed
- moves a broken, pip-installed bbbctl out of the way

## Usage

Run as root inside tmux or screen.

```
wget https://raw.githubusercontent.com/michelleDeko/bbb-4.0-upgrade-script/refs/heads/main/upgrade_to_bbb40.sh
chmod +x upgrade_to_bbb40.sh

# Phase 1 on Ubuntu 22.04, then reboot
./upgrade_to_bbb40.sh -- -s bbb.example.com -e info@example.com

# Phase 2 on Ubuntu 24.04, after the reboot
./upgrade_to_bbb40.sh -- -s bbb.example.com -e info@example.com
```

Everything after `--` goes to bbb-install.sh: pass the options the server was installed with. `./upgrade_to_bbb40.sh --help` lists the script's own options.
