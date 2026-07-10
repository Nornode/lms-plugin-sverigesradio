#!/usr/bin/env bash
# Local LMS dev harness for the Sveriges Radio plugin.
# Edit plugin files in ../SverigesRadio/ and they appear live in the container.

set -euo pipefail

cd "$(dirname "$0")"
DEV_DIR="$(pwd)"
PLUGIN_DIR="$(cd ../SverigesRadio && pwd)"
CONTAINER="lms-dev"
IMAGE="lmscommunity/lyrionmusicserver:latest"
VOLUME="lms-dev-state"

CMD="${1:-help}"

start_container() {
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    docker start "$CONTAINER" >/dev/null
  else
    docker volume create "$VOLUME" >/dev/null
    docker run -d \
      --name "$CONTAINER" \
      -p 9000:9000 \
      -p 9090:9090 \
      -p 3483:3483/tcp \
      -p 3483:3483/udp \
      -v "$PLUGIN_DIR":/config/cache/InstalledPlugins/Plugins/SverigesRadio \
      -v "$VOLUME":/config \
      -e TZ=Europe/Stockholm \
      "$IMAGE" >/dev/null
  fi
}

find_log() {
  docker exec "$CONTAINER" sh -c '
    for f in /config/logs/server.log /config/Logs/server.log /var/log/squeezeboxserver/server.log; do
      [ -f "$f" ] && echo "$f" && exit 0
    done
  '
}

case "$CMD" in
  up)
    start_container
    echo ""
    echo "  LMS web UI:  http://localhost:9000"
    echo "  CLI:         nc localhost 9090"
    echo ""
    echo "  Waiting for server to come up..."
    for i in $(seq 1 30); do
      if curl -s -o /dev/null -w '%{http_code}' http://localhost:9000 | grep -q 200; then
        echo "  Ready."
        break
      fi
      sleep 1
    done
    echo ""
    echo "  Next steps:"
    echo "    1. Open http://localhost:9000 (finish first-run wizard if shown)"
    echo "    2. Settings → Plugins → tick 'Sveriges Radio' → Apply → Restart"
    echo "    3. Watch logs:  ./dev.sh logs"
    ;;

  down)
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    ;;

  rm)
    docker stop "$CONTAINER" >/dev/null 2>&1 || true
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
    ;;

  restart)
    # Fast restart of just the LMS process (picks up plugin code changes)
    if echo "restartserver" | nc -w 2 localhost 9090 2>/dev/null; then
      echo "LMS restarting via CLI..."
    else
      docker restart "$CONTAINER" >/dev/null
      echo "Container restarted."
    fi
    ;;

  logs)
    LOG=$(find_log)
    if [ -z "$LOG" ]; then
      echo "server.log not found yet — falling back to container stdout"
      docker logs -f --tail=200 "$CONTAINER"
    else
      echo "Tailing $LOG (Ctrl-C to stop)"
      docker exec "$CONTAINER" tail -F "$LOG"
    fi
    ;;

  grep)
    LOG=$(find_log)
    if [ -n "$LOG" ]; then
      docker exec "$CONTAINER" tail -n 5000 "$LOG" | \
        grep -i --color=always -E 'sverigesradio|SR API|SR live|SR:|\[SverigesRadio\]' || \
        echo "(no matches)"
    fi
    docker logs --tail=2000 "$CONTAINER" 2>&1 | \
      grep -i --color=always -E 'sverigesradio|\[SverigesRadio\]' || true
    ;;

  shell)
    docker exec -it "$CONTAINER" bash 2>/dev/null || docker exec -it "$CONTAINER" sh
    ;;

  debug)
    printf 'logging category:plugin.sverigesradio level:debug\n' | nc -w 2 localhost 9090
    echo "Set plugin.sverigesradio log level to DEBUG"
    ;;

  enable)
    printf 'pref plugin.state:SverigesRadio needs-enable\nrestartserver\n' | nc -w 2 localhost 9090
    echo "Plugin enabled; server restarting..."
    sleep 8
    echo "--- recent SverigesRadio log lines ---"
    docker exec "$CONTAINER" tail -200 /config/logs/server.log | grep -iE 'sverigesradio|\[SverigesRadio\]' || echo "(nothing yet)"
    ;;

  wipe)
    read -p "Delete all LMS state (prefs, cache, logs)? [y/N] " ans
    if [ "$ans" = "y" ]; then
      docker stop "$CONTAINER" >/dev/null 2>&1 || true
      docker rm   "$CONTAINER" >/dev/null 2>&1 || true
      docker volume rm "$VOLUME" >/dev/null 2>&1 || true
      echo "container + volume removed"
    fi
    ;;

  status)
    docker ps -a --filter "name=$CONTAINER"
    ;;

  pull)
    docker pull "$IMAGE"
    ;;

  *)
    cat <<EOF
Usage: ./dev.sh <command>

  up        Start LMS container (first time: opens on :9000)
  down      Stop container (state preserved)
  rm        Stop + remove container
  restart   Fast restart of LMS process (picks up plugin edits)
  logs      Tail server.log
  grep      Show recent SverigesRadio-related log lines
  enable    Enable the plugin + restart + show plugin log lines
  debug     Set plugin.sverigesradio log level to DEBUG
  shell     Open a shell inside the container
  status    Show container status
  pull      Pull latest LMS image
  wipe      Delete state volume + container (fresh install)

Typical dev loop:
  ./dev.sh up            # first time
  ./dev.sh enable        # enable the plugin, see it load
  # edit ../SverigesRadio/*.pm
  ./dev.sh restart
  ./dev.sh grep          # look for [SverigesRadio] warns and errors
EOF
    ;;
esac
