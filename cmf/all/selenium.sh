#!/usr/bin/env bash

# Download and (re)start:
# ./selenium.sh http://example.com/selenium/2.46.jar
# Re-download and (re)start:
# ./selenium.sh http://example.com/selenium/2.53.jar --force
# Restart:
# ./selenium.sh
# Stop:
# ./selenium.sh --stop

ROOT="$(pwd)/.vagrant"
FILENAME="selenium.jar"
DOWNLOAD_URL="http://selenium-release.storage.googleapis.com/2.53/selenium-server-standalone-2.53.1.jar"
DESTINATION="$ROOT/$FILENAME"
LOGFILE="$ROOT/${FILENAME%%.*}"
PIDFILE="$LOGFILE.pid"

if [[ ! -f "$DESTINATION" || "--force" == "$2" ]]; then
  if [ -z "$DOWNLOAD_URL" ]; then
    \echo "You have not specified an URL for Selenium download."
    \exit 1
  fi

  if [ ! -d "$ROOT" ]; then
    \echo "Virtual machine is not running. Try \"vagrant up\" to fix this."
    \exit 2
  fi

  if ! \curl -O "$DOWNLOAD_URL"; then
    \echo "Cannot download the \"$DOWNLOAD_URL\" file."
    \exit 3
  fi

  \mv "${DOWNLOAD_URL##*/}" "$DESTINATION"
fi

if [ -f "$PIDFILE" ]; then
  PID=$(\cat "$PIDFILE")

  if [ -n "$PID" ]; then
    \kill "$PID" > /dev/null 2>&1
  fi
fi

VMUUID=$(\find "$ROOT/machines" -name id -type f -print0 | \xargs \cat)

# @param $1
#   A port on the guest machine.
#
# @return
#   A port on the host machine.
get_forwarded_port()
{
  local PORT

  PORT=$(\VBoxManage showvminfo "$VMUUID" --details --machinereadable | \awk -v port="$1" -F ',' '$1 ~ port {print $4}')

  if [ -z "$PORT" ]; then
    PORT="$1"
  fi

  echo "$PORT"
}

get_ip()
{
  \VBoxManage guestproperty enumerate "$VMUUID" --patterns /VirtualBox/GuestInfo/Net/1/V4/IP | \awk '{print $4}' | \tr -d ','
}

if [ "--stop" != "$DOWNLOAD_URL" ]; then
  \nohup \java -jar "$DESTINATION" -role node -hub http://$(get_ip):$(get_forwarded_port "4444")/grid/register > "$LOGFILE.out.log" 2> "$LOGFILE.error.log" < /dev/null &
  \echo $! > "$PIDFILE"
fi
