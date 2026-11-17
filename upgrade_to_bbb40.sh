#!/usr/bin/env bash
#
# Upgrades a BigBlueButton 3.0 server on Ubuntu 22.04 in place to
# BigBlueButton 4.0 on Ubuntu 24.04. Upstream does not support this path and
# recommends a fresh 24.04 server, so snapshot the VM first: do-release-upgrade
# cannot be rolled back.
#
# The script runs twice and picks the phase from the running release:
#
#   Phase 1 on 22.04: preflight checks, pending jammy updates, a config backup,
#   removal of the BBB 3.0 packages, removal of the jammy-only apt sources,
#   do-release-upgrade. The package removal keeps /etc/bigbluebutton
#   (overrides, apply-config.sh, livekit*.yaml), /var/bigbluebutton
#   (recordings) and Greenlight.
#
#   Phase 2 on 24.04, after the reboot: Docker source for noble, a fresh
#   PostgreSQL 16 cluster on port 5432 (BBB recreates its databases on every
#   install, nothing is migrated), yq -> yq-go in the bbb-conf scripts, the
#   TURN override of 3.0, then bbb-install.sh for 4.0 (branch tip) with the
#   options given in phase 1, the optional packages of the 3.0 install, cleanup
#   of settings 4.0 dropped, purge of the obsolete jammy packages, repair of
#   bbbctl and the bbb-livekit-stt service where the server has them, and a
#   list of what needs a manual look.
#
# Obsolete packages are only purged when phase 1 recorded the Ubuntu archive
# or one of the jammy PPAs of bbb-install 3.0 as their source, and only when
# the purge takes nothing else along. Packages of third-party sources that
# do-release-upgrade disabled, and local debs, stay and show up in the list.
#
# Before phase 1, take the server out of Scalelite and let the recording queue
# drain: the script refuses to start while meetings run or recordings are
# queued. Run it inside tmux or screen.
#
# State, backup and log go to /root/bbb40-upgrade (mode 0700). Backup and log
# hold secrets (shared secret, TURN secret, TLS keys): delete the directory
# once the server runs fine.
#
#   ./upgrade_to_bbb40.sh --check -- -s bbb.example.com -e admin@example.com
#   ./upgrade_to_bbb40.sh -- -s bbb.example.com -e admin@example.com -g
#   ./upgrade_to_bbb40.sh            # after the reboot: phase 2
#
# Everything after -- goes to bbb-install.sh, except -v (the script sets
# -v noble-400). Pass the options the server was installed with; phase 2
# reuses them unless it gets new ones.
#
set -euo pipefail
umask 022

STATE_DIR="${STATE_DIR:-/root/bbb40-upgrade}"
BBB_VERSION="noble-400"
# Branch of bbb-install for 4.0: every run downloads its current
# bbb-install.sh. --bbb-install-ref <commit> pins a fixed version instead.
BBB_INSTALL_REF="v4.0.x-release"
REPO_HOST="ubuntu.bigbluebutton.org"
KNOWN_DATABASES="postgres bbb_graphql hasura_app blocknote_app"
APT_CONF_OVERRIDE="/etc/apt/apt.conf.d/99zz-bbb40-upgrade"
# PPAs and sources bbb-install 3.0 added; none of them has noble packages BBB 4.0 needs
JAMMY_SOURCES="bigbluebutton nodesource docker rmescandon-ubuntu-yq-jammy bigbluebutton-ubuntu-support-jammy martin-uni-mainz-ubuntu-coturn-jammy"
# bbb-web.properties settings 4.0 no longer reads
DROPPED_PROPERTIES='^[[:space:]]*(sharedNotesEditor|enteredUsersTimeout|clientLogoutTimerInMinutes)[[:space:]]*='
# Client settings and layouts 4.0 removed (see new-features.md of 4.0)
DROPPED_CLIENT_SETTINGS='CUSTOM_LAYOUT|SMART_LAYOUT|PRESENTATION_FOCUS|VIDEO_FOCUS|enableDeprecatedLayoutSelection|showPushLayout|clientSettings|sipjs|etherpad|pads:'
# Origins (Release files) whose obsolete leftovers phase 2 may purge
OBSOLETE_ORIGINS="Ubuntu,UbuntuESM,UbuntuESMApps,LP-PPA-rmescandon-yq,LP-PPA-bigbluebutton-support,LP-PPA-martin-uni-mainz-coturn"
# Where uv puts the Python for the venv of bbb-livekit-stt; the service user must be able to read it
UV_PYTHON_DIR="/usr/local/share/uv/python"

CHECK_ONLY=0
ASSUME_YES=0
AUTO_REBOOT=0
INTERACTIVE=0
SKIP_MEETINGS=0
SKIP_RECORDINGS=0
DROP_UNKNOWN_DB=0
NO_TMUX=0
INSTALL_ARGS=()
NORMALIZED_ARGS=()
HOST=""
COTURN=""
LINK_PATH=""

usage() {
  cat <<EOF
Usage: upgrade_to_bbb40.sh [options] [-- <bbb-install options>]

  --check                   Phase 1 preflight only, changes nothing
  --yes                     Do not ask for confirmation
  --reboot                  Reboot automatically after do-release-upgrade
  --interactive             Run do-release-upgrade with its interactive frontend
                            (default: DistUpgradeViewNonInteractive)
  --skip-meeting-check      Start even while meetings run
  --skip-recording-check    Start even while recordings are queued
  --drop-unknown-databases  Drop the old PostgreSQL cluster even if it holds
                            databases BBB does not own
  --no-tmux                 Allow running outside tmux/screen
  --bbb-install-ref REF     Git ref of bbb-install.sh to download
                            [$BBB_INSTALL_REF]
  -h, --help                Show this help

Phase 1 (22.04):  upgrade_to_bbb40.sh -- -s bbb.example.com -e admin@example.com [-g] [-c turn.example.com:SECRET]
Phase 2 (24.04):  upgrade_to_bbb40.sh
EOF
}

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { say "WARNING: $*" >&2; }
die() {
  say "ERROR: $*" >&2
  exit 1
}

# A problem a step cannot solve: warn now, list it again in the report.
note() {
  warn "$*"
  printf '%s\n' "$*" >>"$STATE_DIR/notes.txt"
}

cleanup() { rm -f "$APT_CONF_OVERRIDE"; }
trap cleanup EXIT

# Conffile policy (confnew or confold) for every apt run until the script exits.
apt_conffiles() { printf 'Dpkg::Options { "--force-confdef"; "--force-%s"; };\n' "$1" >"$APT_CONF_OVERRIDE"; }

codename() { (. /etc/os-release && echo "${VERSION_CODENAME:-}"); }

indent() { sed 's/^/    /'; }

pkg_installed() {
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)" = installed ]
}

is_masked() { [ "$(readlink "/etc/systemd/system/$1" 2>/dev/null || true)" = /dev/null ]; }

# The postrm of a removed package masks its unit.
unmask_unit() {
  if ! is_masked "$1"; then
    return 0
  fi
  deb-systemd-helper unmask "$1" >/dev/null 2>&1 || true
  if is_masked "$1"; then
    systemctl unmask "$1"
  fi
  say "unmasked $1, the removal of its old package had masked it"
}

step_done() { [ -f "$STATE_DIR/steps/$1" ]; }

run_step() {
  local name=$1
  shift
  if step_done "$name"; then
    say "skip $name (done in an earlier run)"
    return 0
  fi
  say "== $name"
  "$@"
  touch "$STATE_DIR/steps/$name"
}

confirm() {
  local answer
  if [ "$ASSUME_YES" = 1 ]; then
    return 0
  fi
  read -r -p "$1 Type 'upgrade' to continue: " answer
  [ "$answer" = upgrade ] || die "aborted"
}

# Prints bbb-install options with the secrets of -c and -t masked.
masked_args() {
  local arg prev="" out=()
  for arg in "$@"; do
    case $prev in
      -c | -t) out+=("${arg%%:*}:***") ;;
      *) out+=("$arg") ;;
    esac
    prev=$arg
  done
  echo "${out[*]}"
}

save_args() {
  (
    umask 077
    printf '%s\0' "${INSTALL_ARGS[@]}" >"$STATE_DIR/bbb-install.args"
  )
}

load_args() {
  [ -s "$STATE_DIR/bbb-install.args" ] || die "no bbb-install options given and none saved by phase 1"
  mapfile -d '' -t INSTALL_ARGS <"$STATE_DIR/bbb-install.args"
}

# Validates the bbb-install options with the getopts string of bbb-install 4.0
# and normalizes them (combined flags split, -m kept apart).
parse_install_args() {
  local opt OPTIND=1
  [ ${#INSTALL_ARGS[@]} -gt 0 ] || die "bbb-install options missing, e.g. -- -s bbb.example.com -e admin@example.com"
  NORMALIZED_ARGS=()
  HOST=""
  COTURN=""
  LINK_PATH=""
  while getopts ":hs:r:c:v:e:p:m:t:xgadwWjikb" opt "${INSTALL_ARGS[@]}"; do
    case $opt in
      v) die "do not pass -v, the script sets -v $BBB_VERSION" ;;
      h) die "-h is no install option" ;;
      m) LINK_PATH=$OPTARG ;;
      s | r | c | e | p | t)
        NORMALIZED_ARGS+=("-$opt" "$OPTARG")
        case $opt in
          s) HOST=$OPTARG ;;
          r) REPO_HOST=$OPTARG ;;
          c) COTURN=$OPTARG ;;
        esac
        ;;
      :) die "bbb-install option -$OPTARG needs a value" ;;
      \?) die "bbb-install 4.0 does not know the option -$OPTARG" ;;
      *) NORMALIZED_ARGS+=("-$opt") ;;
    esac
  done
  [ "$OPTIND" -gt ${#INSTALL_ARGS[@]} ] || die "unexpected bbb-install argument: ${INSTALL_ARGS[$((OPTIND - 1))]}"
  [ -n "$HOST" ] || die "bbb-install option -s <hostname> is required"
}

in_multiplexer() {
  local pid=$$ comm
  if [ -n "${TMUX:-}${STY:-}" ]; then
    return 0
  fi
  # sudo drops TMUX/STY, so walk up the process tree as well
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
    case $comm in
      tmux* | screen* | SCREEN*) return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
  done
  return 1
}

check_tmux() {
  if [ "$NO_TMUX" = 1 ] || in_multiplexer; then
    return 0
  fi
  die "run inside tmux or screen: a dropped SSH session during the upgrade leaves a half-upgraded server (or pass --no-tmux)"
}

check_repo() {
  curl -fsS -o /dev/null "https://$REPO_HOST/$BBB_VERSION/dists/bigbluebutton-noble/Release.gpg" ||
    die "no $BBB_VERSION packages at $REPO_HOST"
}

# Downloads bbb-install.sh from GitHub on every run, never reuses a copy on
# the system.
fetch_bbb_install() {
  local target="$STATE_DIR/bbb-install.sh"
  local url="https://raw.githubusercontent.com/bigbluebutton/bbb-install/$BBB_INSTALL_REF/bbb-install.sh"
  rm -f "$target" "$target.tmp"
  curl -fsSL -o "$target.tmp" "$url" || die "cannot download bbb-install.sh from $url"
  mv "$target.tmp" "$target"
  chmod 0700 "$target"
  say "bbb-install.sh from GitHub ($BBB_INSTALL_REF)"
  bash -n "$target" || die "$target is no valid bash script"
  grep -q 'noble-4' "$target" || die "$target is not the bbb-install.sh for BigBlueButton 4.0"
  say "bbb-install.sh sha256 $(sha256sum "$target" | cut -d' ' -f1)"
}

check_meetings() {
  local props salt="" checksum xml count
  if [ "$SKIP_MEETINGS" = 1 ]; then
    warn "meeting check skipped"
    return 0
  fi
  for props in /etc/bigbluebutton/bbb-web.properties /usr/share/bbb-web/WEB-INF/classes/bigbluebutton.properties; do
    salt=$(sed -n 's/^securitySalt=//p' "$props" 2>/dev/null | tail -n1 || true)
    if [ -n "$salt" ]; then
      break
    fi
  done
  [ -n "$salt" ] || die "securitySalt not found, cannot check for running meetings (or pass --skip-meeting-check)"
  checksum=$(printf 'getMeetings%s' "$salt" | sha256sum | cut -d' ' -f1)
  salt=""
  xml=$(curl -fsS --max-time 15 "http://127.0.0.1:8090/bigbluebutton/api/getMeetings?checksum=$checksum") ||
    die "bbb-web did not answer getMeetings on 127.0.0.1:8090 (or pass --skip-meeting-check)"
  grep -q '<returncode>SUCCESS</returncode>' <<<"$xml" || die "getMeetings did not return SUCCESS"
  count=$(grep -o '<meetingID>' <<<"$xml" | wc -l || true)
  [ "$count" -eq 0 ] || die "$count meeting(s) running: take the server out of Scalelite and wait (or pass --skip-meeting-check)"
  say "no meetings running"
}

check_recordings() {
  local key len queued=0 working
  if [ "$SKIP_RECORDINGS" = 1 ]; then
    warn "recording check skipped"
    return 0
  fi
  command -v redis-cli >/dev/null 2>&1 || die "redis-cli missing, cannot check the recording queue (or pass --skip-recording-check)"
  [ "$(redis-cli ping 2>/dev/null || true)" = PONG ] || die "redis does not answer, cannot check the recording queue (or pass --skip-recording-check)"
  while read -r key; do
    if [ -n "$key" ]; then
      len=$(redis-cli llen "$key")
      queued=$((queued + len))
    fi
  done < <(redis-cli --scan --pattern 'resque:queue:rap:*')
  # resque:worker:<id> exists while that worker processes a job
  working=$(redis-cli --scan --pattern 'resque:worker:*' | grep -vc ':started$' || true)
  if [ "$queued" -gt 0 ] || [ "$working" -gt 0 ]; then
    die "recording processing busy ($queued queued, $working running): wait until it drains (or pass --skip-recording-check)"
  fi
  say "recording queue empty"
}

check_databases() {
  local dbs db unknown=()
  if ! command -v psql >/dev/null 2>&1; then
    return 0
  fi
  if ! dbs=$(cd / && runuser -u postgres -- psql -p 5432 -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate" 2>/dev/null); then
    warn "cannot list the databases on port 5432"
    return 0
  fi
  for db in $dbs; do
    case " $KNOWN_DATABASES " in
      *" $db "*) ;;
      *) unknown+=("$db") ;;
    esac
  done
  if [ ${#unknown[@]} -gt 0 ]; then
    if [ "$DROP_UNKNOWN_DB" = 1 ]; then
      warn "phase 2 drops these databases with the old cluster: ${unknown[*]}"
    else
      die "the local PostgreSQL holds databases BBB does not own: ${unknown[*]}. Phase 2 drops the old cluster; move them first or pass --drop-unknown-databases"
    fi
  fi
}

check_system() {
  local avail holds
  [ "$(uname -m)" = x86_64 ] || die "64-bit x86 server required"
  [ -z "$(dpkg --audit 2>&1)" ] || die "dpkg reports half-installed packages, fix them first (dpkg --audit)"
  holds=$(apt-mark showhold | tr '\n' ' ')
  if [ -n "$holds" ]; then
    warn "held packages can block do-release-upgrade: $holds"
  fi
  avail=$(df -BG --output=avail / | tail -n1 | tr -dc '0-9')
  [ "$avail" -ge 5 ] || die "only ${avail} GB free on /, do-release-upgrade needs about 5 GB"
}

preflight_phase1() {
  local release
  release=$(sed -n 's/^BIGBLUEBUTTON_RELEASE=//p' /etc/bigbluebutton/bigbluebutton-release 2>/dev/null | tail -n1 || true)
  case $release in
    3.0.*) say "BigBlueButton $release on Ubuntu 22.04" ;;
    *) die "BigBlueButton 3.0.x expected, found '${release:-nothing}'" ;;
  esac
  check_tmux
  check_system
  check_repo
  fetch_bbb_install
  check_databases
  if ! step_done remove-bbb; then
    check_meetings
    check_recordings
  fi
  say "bbb-install options: -v $BBB_VERSION $(masked_args "${NORMALIZED_ARGS[@]}")${LINK_PATH:+ -m $LINK_PATH}"
}

step_jammy_update() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
  DEBIAN_FRONTEND=noninteractive apt-get -y install ubuntu-release-upgrader-core
}

step_backup() {
  local paths=() p
  for p in etc/bigbluebutton etc/turnserver.conf etc/systemd/system/coturn.service.d etc/haproxy etc/nginx \
    etc/letsencrypt etc/default/bbb-graphql-server-admin-pass etc/apt opt/freeswitch/conf \
    usr/share/bigbluebutton/nginx usr/local/bigbluebutton/core/scripts/bigbluebutton.yml \
    root/greenlight-v3/.env root/greenlight-v3/docker-compose.yml; do
    if [ -e "/$p" ]; then
      paths+=("$p")
    fi
  done
  tar -C / -czf "$STATE_DIR/backup-bbb30.tar.gz" "${paths[@]}"
  dpkg --get-selections >"$STATE_DIR/dpkg-selections.txt"
  apt-mark showmanual >"$STATE_DIR/apt-manual.txt"
  # Source of every installed package while all jammy sources are still active;
  # phase 2 only purges obsolete packages from the sources in OBSOLETE_ORIGINS
  python3 -I - >"$STATE_DIR/package-origins.txt" <<'PY'
import apt

for pkg in apt.Cache():
    if pkg.is_installed:
        origins = sorted({o.origin for o in pkg.installed.origins if o.origin})
        print(pkg.name, ",".join(origins) or "-")
PY
  say "backup: $STATE_DIR/backup-bbb30.tar.gz"
}

step_remove_bbb() {
  local pkgs=() purge=() keep=() p
  check_meetings
  mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null |
    awk '$1 == "installed" && ($2 == "bigbluebutton" || $2 ~ /^bbb-/) {print $2}')
  [ ${#pkgs[@]} -gt 0 ] || die "no BigBlueButton packages installed"
  printf '%s\n' "${pkgs[@]}" >"$STATE_DIR/bbb30-packages.txt"
  for p in "${pkgs[@]}"; do
    case $p in
      bbb-etherpad | bbb-pads) purge+=("$p") ;;
    esac
  done
  # Keep what BBB pulled in as dependency, so nothing auto-removes it during the OS upgrade
  for p in nginx redis-server haproxy coturn certbot ufw docker-ce docker-ce-cli containerd.io docker-compose-plugin; do
    if pkg_installed "$p"; then
      keep+=("$p")
    fi
  done
  if [ ${#keep[@]} -gt 0 ]; then
    apt-mark manual "${keep[@]}" >/dev/null
  fi
  bbb-conf --stop || warn "bbb-conf --stop failed, removing the packages anyway"
  # remove, not purge: conffiles and the config-files state stay for the 4.0 install
  DEBIAN_FRONTEND=noninteractive apt-get -y remove "${pkgs[@]}"
  # Etherpad is gone in 4.0; upstream asks for a purge
  if [ ${#purge[@]} -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "${purge[@]}"
  fi
}

step_apt_sources() {
  local dir="$STATE_DIR/apt-sources-jammy" name f others
  mkdir -p "$dir"
  for name in $JAMMY_SOURCES; do
    for f in "/etc/apt/sources.list.d/$name.list" "/etc/apt/sources.list.d/$name.sources"; do
      if [ -e "$f" ]; then
        mv "$f" "$dir/"
        say "moved $f to $dir"
      fi
    done
  done
  apt-get update
  others=$(find /etc/apt/sources.list.d -maxdepth 1 -type f \( -name '*.list' -o -name '*.sources' \) -printf '%f ')
  if [ -n "$others" ]; then
    warn "do-release-upgrade disables these sources, re-enable them for noble afterwards: $others"
  fi
}

step_prepare_release_upgrade() {
  if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
    die "nginx -t fails after the BBB removal, so the nginx upgrade would fail: fix the nginx config and run again"
  fi
  # do-release-upgrade over SSH starts a fallback sshd on port 1022
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 1022/tcp comment 'bbb40-upgrade: fallback sshd of do-release-upgrade' >/dev/null
    touch "$STATE_DIR/ufw-1022"
  fi
  if [ -f /etc/update-manager/release-upgrades ]; then
    sed -i 's/^Prompt=.*/Prompt=lts/' /etc/update-manager/release-upgrades
  fi
}

step_release_upgrade() {
  local args=()
  [ ! -f /run/reboot-required ] || die "a reboot is pending: reboot, then run the script again"
  if [ "$INTERACTIVE" != 1 ]; then
    args=(-f DistUpgradeViewNonInteractive)
  fi
  say "starting do-release-upgrade ${args[*]} (logs in /var/log/dist-upgrade/)"
  # straight to the terminal, the interactive frontend needs a tty
  if ! do-release-upgrade "${args[@]}" >&3 2>&4; then
    die "do-release-upgrade failed, see /var/log/dist-upgrade/main.log"
  fi
  [ "$(codename)" = noble ] || die "do-release-upgrade returned, but the system is on $(codename): see /var/log/dist-upgrade/"
}

phase1() {
  if [ ${#INSTALL_ARGS[@]} -eq 0 ] && [ -s "$STATE_DIR/bbb-install.args" ]; then
    load_args
  fi
  parse_install_args
  preflight_phase1
  if [ "$CHECK_ONLY" = 1 ]; then
    say "preflight passed, nothing changed"
    return 0
  fi
  save_args
  confirm "Phase 1 removes BigBlueButton 3.0 and upgrades this server to Ubuntu 24.04. Snapshot taken, server out of Scalelite?"

  run_step jammy-update step_jammy_update
  if [ -f /run/reboot-required ]; then
    say "the jammy updates need a reboot before do-release-upgrade: reboot, then run the script again"
    exit 0
  fi
  run_step backup step_backup
  run_step remove-bbb step_remove_bbb
  run_step apt-sources step_apt_sources
  run_step prepare-release-upgrade step_prepare_release_upgrade
  run_step release-upgrade step_release_upgrade

  say "phase 1 done. Reboot, then run this script again (inside tmux) for phase 2."
  if [ "$AUTO_REBOOT" = 1 ]; then
    say "rebooting in 10 seconds"
    sleep 10
    systemctl reboot
  fi
}

step_close_fallback_ssh() {
  if [ -f "$STATE_DIR/ufw-1022" ]; then
    ufw delete allow 1022/tcp >/dev/null || warn "could not remove the ufw rule for port 1022"
    rm -f "$STATE_DIR/ufw-1022"
  fi
}

step_docker_noble() {
  local keyring=/usr/share/keyrings/docker-archive-keyring.gpg
  if ! pkg_installed docker-ce; then
    return 0
  fi
  if [ ! -s "$keyring" ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --batch --yes --dearmor -o "$keyring"
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://download.docker.com/linux/ubuntu noble stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
}

# BBB 4.0 expects PostgreSQL 16 on port 5432 (Hasura, akka-apps, shared notes,
# bbb-pg.conf under /etc/postgresql/16). After do-release-upgrade the old 14
# cluster still holds 5432. BBB drops and recreates its databases on every
# install, so the clusters are recreated instead of migrated.
step_postgres() {
  local ver name port rest old_pkgs=()
  if command -v pg_lsclusters >/dev/null 2>&1; then
    while read -r ver name port rest; do
      if [ "$ver" != 16 ] || [ "$port" != 5432 ]; then
        say "dropping PostgreSQL cluster $ver/$name (port $port)"
        pg_dropcluster --stop "$ver" "$name" </dev/null
      fi
    done < <(pg_lsclusters -h)
  fi
  mapfile -t old_pkgs < <(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 2>/dev/null |
    awk '$1 == "installed" && $2 ~ /^postgresql-(client-)?1[0-5]$/ {print $2}')
  if [ ${#old_pkgs[@]} -gt 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "${old_pkgs[@]}"
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -y install postgresql-16
  if ! pg_lsclusters -h | awk '$1 == 16 && $2 == "main"' | grep -q .; then
    pg_createcluster 16 main -p 5432
  fi
  systemctl start postgresql@16-main
  case "$(cd / && runuser -u postgres -- psql -p 5432 -tAc 'SHOW server_version_num')" in
    16*) say "PostgreSQL 16 runs on port 5432" ;;
    *) die "port 5432 is not served by PostgreSQL 16 (pg_lsclusters)" ;;
  esac
}

# The 4.0 tooling only ships /usr/bin/yq-go (bbb-yq-go); the yq of noble is the
# Python yq with a different syntax. Both are mikefarah yq 4, so renaming works.
step_yq_go() {
  local f
  for f in /etc/bigbluebutton/bbb-conf/*.sh; do
    if [ ! -f "$f" ] || [ -L "$f" ]; then
      continue
    fi
    if grep -Eq '(^|[^[:alnum:]_./-])yq[[:space:]]|/usr/bin/yq[[:space:]]' "$f"; then
      cp -p "$f" "$STATE_DIR/$(basename "$f").bbb30"
      sed -E -i -e 's#/usr/bin/yq([[:space:]])#/usr/bin/yq-go\1#g' \
        -e 's/(^|[^[:alnum:]_./-])yq([[:space:]])/\1yq-go\2/g' "$f"
      say "$f: yq -> yq-go (original in $STATE_DIR)"
    fi
  done
}

# 3.0 always wrote /etc/bigbluebutton/turn-stun-servers.xml, which bbb-web
# prefers. Without -c, bbb-install 4.0 writes the TURN config for the local
# coturn into bbb-web itself, so the old override would shadow it.
step_turn_override() {
  local xml=/etc/bigbluebutton/turn-stun-servers.xml
  if [ ! -f "$xml" ]; then
    return 0
  fi
  if [ -n "$COTURN" ]; then
    say "keeping $xml, bbb-install rewrites it for -c"
    return 0
  fi
  mv "$xml" "$STATE_DIR/turn-stun-servers.xml.bbb30"
  say "moved $xml to $STATE_DIR, bbb-install configures the local coturn"
}

step_bbb_install() {
  local final=("${NORMALIZED_ARGS[@]}")
  if [ -n "$LINK_PATH" ]; then
    # a second "ln -s" by bbb-install would fail or nest a link
    if [ -e /var/bigbluebutton ] || [ -L /var/bigbluebutton ]; then
      say "leaving out -m $LINK_PATH, /var/bigbluebutton already exists"
    else
      final+=(-m "$LINK_PATH")
    fi
  fi
  say "running bbb-install.sh -v $BBB_VERSION $(masked_args "${final[@]}")"
  bash "$STATE_DIR/bbb-install.sh" -v "$BBB_VERSION" "${final[@]}"
}

# Removing the old coturn package (PPA or distro) masks coturn.service in its
# postrm. bbb-coturn ships a unit of the same name and does not unmask it, so
# "systemctl enable --now coturn" in bbb-install fails, and bbb-install carries
# on without TURN. Do not purge the old coturn (config-files state) afterwards:
# its postrm purge removes the enable links of coturn.service again.
step_coturn_unmask() {
  if [ -n "$COTURN" ] || ! pkg_installed bbb-coturn; then
    return 0
  fi
  unmask_unit coturn.service
  systemctl daemon-reload
  systemctl enable --now coturn.service
  systemctl is-active --quiet coturn.service || die "coturn does not start, see journalctl -u coturn"
  say "coturn runs"
}

step_extra_packages() {
  local p missing=() gone=()
  if [ -f "$STATE_DIR/bbb30-packages.txt" ]; then
    while read -r p; do
      case $p in
        bbb-etherpad | bbb-pads | "") continue ;;
      esac
      if pkg_installed "$p"; then
        continue
      fi
      if apt-cache show "$p" >/dev/null 2>&1; then
        missing+=("$p")
      else
        gone+=("$p")
      fi
    done <"$STATE_DIR/bbb30-packages.txt"
  fi
  # players for recordings of BBB 0.81 and 0.9 moved into an optional package
  if grep -rqsE --include=metadata.xml '/playback/presentation/(0\.81|0\.9\.0)/' /var/bigbluebutton/published/presentation; then
    missing+=(bbb-playback-presentation-legacy)
  fi
  if [ ${#gone[@]} -gt 0 ]; then
    warn "no 4.0 package for: ${gone[*]}"
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    say "installing the optional packages of the 3.0 install: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -y install "${missing[@]}"
  fi
}

step_config_cleanup() {
  local rec=/etc/bigbluebutton/recording/recording.yml props=/etc/bigbluebutton/bbb-web.properties
  if [ -s "$rec" ]; then
    cp -p "$rec" "$STATE_DIR/recording.yml.bbb30"
    if [ "$(yq-go e '.notes_endpoint != null' "$rec")" = true ]; then
      yq-go -i 'del(.notes_endpoint)' "$rec"
      say "recording.yml: removed notes_endpoint (Etherpad)"
    fi
    if [ "$(yq-go e '(.notes_formats // []) | any_c(. == "etherpad")' "$rec")" = true ]; then
      yq-go -i '.notes_formats |= map(select(. != "etherpad"))' "$rec"
      if [ "$(yq-go e '.notes_formats | length' "$rec")" = 0 ]; then
        yq-go -i 'del(.notes_formats)' "$rec"
      fi
      say "recording.yml: removed etherpad from notes_formats"
    fi
    if [ "$(yq-go e '(.bn_notes_endpoint // "") | (test("/api/documents$") and (test("/loopback/") | not))' "$rec")" = true ]; then
      yq-go -i '.bn_notes_endpoint |= sub("/api/documents$"; "/loopback/api/documents")' "$rec"
      say "recording.yml: bn_notes_endpoint now ends in /loopback/api/documents"
    fi
  fi
  if [ -f "$props" ] && grep -Eq "$DROPPED_PROPERTIES" "$props"; then
    cp -p "$props" "$STATE_DIR/bbb-web.properties.bbb30"
    sed -E -i "/$DROPPED_PROPERTIES/d" "$props"
    say "bbb-web.properties: removed settings 4.0 dropped (original in $STATE_DIR)"
    systemctl restart bbb-web
  fi
}

# Prints "<action> <package> <origins> <version>" for every installed package
# whose installed version no source provides anymore:
#   purge     no version left anywhere, recorded origin in OBSOLETE_ORIGINS
#   downgrade the version of a removed PPA is installed, the archive has another
#   keep      third-party or local origin, or nothing recorded
list_orphaned() {
  python3 -I - "$STATE_DIR/package-origins.txt" "$OBSOLETE_ORIGINS" <<'PY'
import sys

import apt
import apt_pkg

allowed = set(sys.argv[2].split(","))
recorded = {}
with open(sys.argv[1]) as f:
    for line in f:
        name, _, origins = line.rstrip("\n").partition(" ")
        recorded[name] = set() if origins in ("", "-") else set(origins.split(","))

for pkg in apt.Cache():
    if pkg._pkg.current_state != apt_pkg.CURSTATE_INSTALLED or pkg.installed.downloadable:
        continue
    origins = recorded.get(pkg.name, set())
    available = [v for v in pkg.versions if v.downloadable]
    if not origins or not origins <= allowed:
        action, version = "keep", "-"
    elif not available or pkg.shortname == "yq":
        # the yq of noble is the Python yq, not a successor of the PPA's mikefarah yq
        action, version = "purge", "-"
    else:
        action, version = "downgrade", available[0].version
    print(action, pkg.name, ",".join(sorted(origins)) or "-", version)
PY
}

step_obsolete_packages() {
  local action name origin version out r c kernel
  local purge=() downgrade=() kept=()
  local -A candidate=()
  if [ ! -s "$STATE_DIR/package-origins.txt" ]; then
    warn "phase 1 recorded no package origins, obsolete packages stay"
    return 0
  fi
  kernel=$(uname -r)
  while read -r action name origin version; do
    if [[ $name == *"$kernel"* ]]; then
      kept+=("$name (running kernel)")
      continue
    fi
    case $action in
      purge) candidate[$name]=1 ;;
      downgrade) downgrade+=("$name=$version") ;;
      *) kept+=("$name ($origin)") ;;
    esac
  done < <(list_orphaned)

  # A purge also removes everything that depends on the package: only purge
  # packages whose removal stays within the candidates.
  for c in "${!candidate[@]}"; do
    if ! out=$(apt-get -s purge "$c" 2>&1); then
      kept+=("$c (apt refuses the purge)")
      continue
    fi
    while read -r r; do
      if [ -z "${candidate[$r]:-}" ]; then
        kept+=("$c (needed by $r)")
        continue 2
      fi
    done < <(awk '$1 == "Purg" || $1 == "Remv" {print $2}' <<<"$out")
    purge+=("$c")
  done
  if [ ${#purge[@]} -gt 0 ]; then
    say "purging ${#purge[@]} obsolete jammy package(s): ${purge[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "${purge[@]}"
  fi

  for c in "${downgrade[@]}"; do
    if ! out=$(apt-get -s install --allow-downgrades "$c" 2>&1) || grep -qE '^(Remv|Purg) ' <<<"$out"; then
      kept+=("${c%%=*} (switching to ${c#*=} of the archive would remove other packages)")
      continue
    fi
    say "replacing the PPA version of ${c%%=*} with ${c#*=}"
    DEBIAN_FRONTEND=noninteractive apt-get -y install --allow-downgrades "$c"
    # apt-get install marks the package manual; keep it auto if it was a dependency
    if ! grep -qx "${c%%=*}" "$STATE_DIR/apt-manual.txt" 2>/dev/null; then
      apt-mark auto "${c%%=*}" >/dev/null
    fi
  done

  DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
  if [ ${#kept[@]} -gt 0 ]; then
    printf '%s\n' "${kept[@]}" >"$STATE_DIR/obsolete-kept.txt"
  fi
}

# bbb-config of 4.0 ships /usr/bin/bbbctl. A bbbctl that pip installed for the
# Python of 22.04 sits in /usr/local/bin, which comes first in PATH, and fails
# now: its module is in the dist-packages of the Python that is gone.
step_bbbctl() {
  local old=/usr/local/bin/bbbctl dir="$STATE_DIR/bbbctl-pip" d f py
  if [ ! -x /usr/bin/bbbctl ] || [ ! -f "$old" ]; then
    return 0
  fi
  # only the entry point of pip, and only when it is broken
  if ! grep -q '^from bbbctl import' "$old" || "$old" --help >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$dir"
  mv "$old" "$dir/"
  for d in /usr/local/lib/python3.*/dist-packages; do
    py=$(basename "$(dirname "$d")")
    # only the module of a Python version that is gone
    if [ ! -d "$d" ] || [ -x "/usr/bin/$py" ]; then
      continue
    fi
    for f in "$d"/bbbctl.py "$d"/bbbctl-*.dist-info "$d"/__pycache__/bbbctl.*.pyc; do
      if [ -e "$f" ]; then
        mkdir -p "$dir/$py"
        mv "$f" "$dir/$py/"
      fi
    done
  done
  say "moved the bbbctl of pip (Python of 22.04) to $dir, bbbctl is /usr/bin/bbbctl of bbb-config now"
}

# bbb-livekit-stt is no package but a git checkout that its unit starts with
# "uv run" as the service user. The venv points to the Python of 22.04, and the
# service user cannot recreate it in the root-owned checkout, so the unit
# restarts in a loop. Rebuild the venv as root from uv.lock; uv fetches the
# Python version the project pins into UV_PYTHON_DIR.
step_livekit_stt() {
  local unit=bbb-livekit-stt.service dir uv pid
  if [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null || true)" != loaded ]; then
    return 0
  fi
  dir=$(systemctl show -p WorkingDirectory --value "$unit")
  if [ -f "$dir/uv.lock" ] && [ ! -x "$dir/.venv/bin/python" ]; then
    uv=$(command -v uv || true)
    if [ -z "$uv" ]; then
      note "$unit: uv not found, cannot rebuild $dir/.venv"
      return 0
    fi
    say "rebuilding $dir/.venv, the Python of Ubuntu 22.04 it used is gone"
    (cd "$dir" && UV_PYTHON_INSTALL_DIR="$UV_PYTHON_DIR" "$uv" sync --locked)
  fi
  if ! systemctl is-enabled --quiet "$unit"; then
    say "$unit is not enabled, leaving it stopped"
    return 0
  fi
  systemctl restart "$unit"
  # a broken service is "active" for a moment in every restart cycle
  pid=$(systemctl show -p MainPID --value "$unit")
  sleep 10
  if [ "$pid" != 0 ] && [ "$(systemctl show -p MainPID --value "$unit")" = "$pid" ]; then
    say "bbb-livekit-stt runs"
  else
    note "bbb-livekit-stt does not stay up, see journalctl -u bbb-livekit-stt and /var/log/bigbluebutton/bbb-livekit-stt.log"
  fi
}

report() {
  local files disabled hits
  say "== To review by hand"
  files=$(find /etc /usr/local/bigbluebutton -xdev \( -name '*.dpkg-dist' -o -name '*.dpkg-old' -o -name '*.dpkg-new' -o -name '*.ucf-dist' \) \
    -newer "$STATE_DIR/steps/remove-bbb" 2>/dev/null || true)
  if [ -n "$files" ]; then
    say "config files where the package and the local version differ:"
    indent <<<"$files"
  fi
  hits=$(grep -nE "$DROPPED_CLIENT_SETTINGS" /etc/bigbluebutton/bbb-html5.yml /etc/bigbluebutton/bbb-conf/apply-config.sh 2>/dev/null || true)
  if [ -n "$hits" ]; then
    say "settings that 4.0 removed (layouts, Etherpad, SIP.js, clientSettings):"
    indent <<<"$hits"
  fi
  if [ -s "$STATE_DIR/notes.txt" ]; then
    say "problems the steps could not solve:"
    sort -u "$STATE_DIR/notes.txt" | indent
  fi
  # not the *.distUpgrade backups of the upgrader, apt ignores those
  disabled=$(grep -lE 'disabled on upgrade to|^Enabled: no' /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null || true)
  if [ -n "$disabled" ]; then
    say "apt sources do-release-upgrade disabled:"
    indent <<<"$disabled"
  fi
  if [ -s "$STATE_DIR/obsolete-kept.txt" ]; then
    say "packages no source provides anymore that the script kept:"
    indent <"$STATE_DIR/obsolete-kept.txt"
  fi
  if ! command -v yq >/dev/null 2>&1; then
    hits=$(grep -lsIE '(^|[^[:alnum:]_./-])yq[[:space:]]' /etc/cron.d/* /etc/cron.hourly/* /etc/cron.daily/* \
      /etc/cron.weekly/* /etc/cron.monthly/* /var/spool/cron/crontabs/* /usr/local/bin/* /usr/local/sbin/* /root/*.sh || true)
    if [ -n "$hits" ]; then
      say "scripts that still call yq, which is gone now (switch them to yq-go):"
      indent <<<"$hits"
    fi
  fi
  say "next: test meeting (audio, camera, screen sharing via LiveKit), test recording, enable the server in Scalelite again"
  say "then delete $STATE_DIR, it holds secrets"
}

phase2() {
  step_done remove-bbb || die "phase 1 has not run on this server ($STATE_DIR/steps/remove-bbb missing)"
  [ ! -f /run/reboot-required ] || die "reboot into the 24.04 kernel first"
  if [ ${#INSTALL_ARGS[@]} -eq 0 ]; then
    load_args
  fi
  parse_install_args
  save_args
  check_tmux
  check_repo
  fetch_bbb_install
  say "bbb-install options: -v $BBB_VERSION $(masked_args "${NORMALIZED_ARGS[@]}")${LINK_PATH:+ -m $LINK_PATH}"
  confirm "Phase 2 installs BigBlueButton 4.0 on this Ubuntu 24.04 server."

  export NEEDRESTART_SUSPEND=1
  # Same conffile policy as the dist-upgrade of bbb-install, also for its plain installs
  apt_conffiles confnew

  run_step close-fallback-ssh step_close_fallback_ssh
  run_step docker-noble step_docker_noble
  run_step postgres-16 step_postgres
  run_step yq-go step_yq_go
  run_step turn-override step_turn_override
  run_step bbb-install step_bbb_install
  run_step coturn-unmask step_coturn_unmask
  run_step extra-packages step_extra_packages
  run_step config-cleanup step_config_cleanup
  run_step obsolete-packages step_obsolete_packages
  run_step bbbctl step_bbbctl
  run_step livekit-stt step_livekit_stt
  report
  say "phase 2 done: $(sed -n 's/^BIGBLUEBUTTON_RELEASE=//p' /etc/bigbluebutton/bigbluebutton-release | tail -n1) on Ubuntu $(. /etc/os-release && echo "$VERSION_ID")"
}

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --check) CHECK_ONLY=1 ;;
      --yes) ASSUME_YES=1 ;;
      --reboot) AUTO_REBOOT=1 ;;
      --interactive) INTERACTIVE=1 ;;
      --skip-meeting-check) SKIP_MEETINGS=1 ;;
      --skip-recording-check) SKIP_RECORDINGS=1 ;;
      --drop-unknown-databases) DROP_UNKNOWN_DB=1 ;;
      --no-tmux) NO_TMUX=1 ;;
      --bbb-install-ref)
        BBB_INSTALL_REF=${2:?--bbb-install-ref needs a value}
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      --)
        shift
        INSTALL_ARGS=("$@")
        break
        ;;
      *) die "unknown option $1 (bbb-install options go after --)" ;;
    esac
    shift
  done

  [ "$(id -u)" -eq 0 ] || die "run as root"
  mkdir -p "$STATE_DIR/steps"
  chmod 0700 "$STATE_DIR"
  touch "$STATE_DIR/upgrade.log"
  chmod 0600 "$STATE_DIR/upgrade.log"
  exec 3>&1 4>&2
  exec > >(tee -a "$STATE_DIR/upgrade.log") 2>&1
  say "log: $STATE_DIR/upgrade.log"

  case "$(codename)" in
    jammy) phase1 ;;
    noble)
      [ "$CHECK_ONLY" = 0 ] || die "--check covers phase 1 on Ubuntu 22.04 only"
      phase2
      ;;
    *) die "Ubuntu 22.04 or 24.04 expected, found '$(codename)'" ;;
  esac
}

main "$@"
