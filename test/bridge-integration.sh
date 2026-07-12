#!/usr/bin/env bash
# bridge-integration.sh — end-to-end proof that magnus-bridge.el is a
# real remote-transport client of the bridge daemon.
#
# It builds a SCRATCH daemon from the sibling bridge repo into a temp dir,
# boots it under a throwaway HOME on a random port (never touching ~/.bridge,
# ~/bin, launchd, or any running daemon), starts an emacs --batch client that
# hosts one fake agent ("wolf-sim") over the four /local/transport endpoints,
# and asserts from the shell side:
#   (i)   the agent shows up live on the remote transport, flavor "emacs";
#   (ii)  a phone send lands in the agent's buffer exactly once (delivered +
#         acked — no redelivery), typed by the client's real drain/ack loop;
#   (iii) an attested dialog-frame tail flips the contact's prompt_open.
#
# Requires go, tmux, emacs, curl, python3 and a sibling bridge checkout.
# Bounded well under 90s; a trap kills everything.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_REPO="${BRIDGE_REPO:-$(cd "$ROOT/.." 2>/dev/null && pwd)/bridge}"

# --- preflight -------------------------------------------------------------
fail() { echo "FAIL: $1"; exit 1; }
for t in go tmux emacs curl python3; do
  command -v "$t" >/dev/null 2>&1 || fail "$t not available"
done
[ -d "$BRIDGE_REPO" ] || fail "bridge repo not found at $BRIDGE_REPO"
[ -f "$BRIDGE_REPO/go.mod" ] || fail "bridge repo has no go.mod (not the Go daemon)"

# --- isolate everything under one temp dir ---------------------------------
TMP="$(mktemp -d)"
HOME_DIR="$TMP/home"
BIN="$TMP/bridged"
LOG="$TMP/server.log"
CLIENT_EL="$TMP/client.el"
EMACS_LOG="$TMP/emacs.log"
TYPED="$TMP/typed.log"          # the type-stub appends each typed delivery here
INJECT="$TMP/inject-dialog"     # touch -> client injects a dialog frame
STOP="$TMP/stop"                # touch -> client exits its host loop
mkdir -p "$HOME_DIR/.bridge"
# The scratch daemon config the mission mandates: no identity gate (so curl can
# pair), a 3s lease TTL and a 2s ack timeout to keep lease/redelivery timings
# smoke-fast.
printf '%s\n' '{"require_identity": false, "remote_ttl_s": 3, "remote_ack_timeout_s": 2}' \
  > "$HOME_DIR/.bridge/config.json"

PORT=$(( (RANDOM % 5000) + 40000 ))
BASE="http://127.0.0.1:$PORT"

SERVER_PID=""
EMACS_PID=""
cleanup() {
  touch "$STOP" 2>/dev/null || true
  [ -n "$EMACS_PID" ] && kill "$EMACS_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && { pkill -P "$SERVER_PID" 2>/dev/null; kill "$SERVER_PID" 2>/dev/null; }
  sleep 0.2
  [ -n "$EMACS_PID" ] && kill -9 "$EMACS_PID" 2>/dev/null
  [ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   - $1"; }
bad()  { fail=$((fail+1)); echo "FAIL - $1"; }

# --- port guard -------------------------------------------------------------
if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
  fail "random port $PORT already in use"
fi

# --- build the scratch daemon (read-only from the bridge repo) --------------
if ! (cd "$BRIDGE_REPO" && go build -o "$BIN" .) >"$TMP/build.log" 2>&1; then
  echo "FAIL: go build of the bridge daemon failed"; cat "$TMP/build.log"; exit 1
fi

# --- boot the isolated daemon ----------------------------------------------
HOME="$HOME_DIR" BRIDGE_COALESCE_MS=300 "$BIN" serve --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!
for _ in $(seq 40); do
  [ -f "$HOME_DIR/.bridge/daemon.json" ] && curl -s -o /dev/null "$BASE/" && break
  sleep 0.25
done
if ! curl -s -o /dev/null "$BASE/"; then
  echo "FAIL: scratch daemon did not start"; cat "$LOG"; exit 1
fi
LOCAL_TOKEN=$(sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p' "$HOME_DIR/.bridge/daemon.json")
[ -n "$LOCAL_TOKEN" ] || { echo "FAIL: no local token in daemon.json"; cat "$LOG"; exit 1; }

J=(-H "Content-Type: application/json")
LOCAL_AUTH=(-H "Authorization: Bearer $LOCAL_TOKEN")

# --- write the emacs client driver -----------------------------------------
SESSION="$(uuidgen 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')"
cat > "$CLIENT_EL" <<'ELISP'
;; -*- lexical-binding: t; -*-
;; A minimal live host: one fake agent in a scratch buffer with a real (sleep)
;; process so the readiness check passes, a type-stub that records deliveries,
;; and a bounded pump loop that also injects a dialog frame on request.
(require 'magnus-bridge)
(let* ((buf (get-buffer-create "wolf-sim"))
       (typed (getenv "RT_TYPED"))
       (inject (getenv "RT_INJECT"))
       (stop (getenv "RT_STOP"))
       (proc (start-process "wolf-proc" buf "sleep" "120")))
  (set-process-query-on-exit-flag proc nil)
  (setq magnus-bridge-daemon-file (getenv "RT_DAEMON")
        magnus-bridge-roster-function
        (lambda ()
          (list (list :instance-id "wolf-1"
                      :name "wolf-sim"
                      :directory (getenv "RT_DIR")
                      :session-id (getenv "RT_SESSION")
                      :provider 'claude
                      :buffer buf)))
        magnus-bridge-type-function
        (lambda (buffer string kind)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert (format "[%s] %s\n" kind string))))
          (write-region (format "%s\t%s\n" kind string) nil typed 'append 0)))
  (magnus-bridge-mode 1)
  (let ((deadline (+ (float-time) 80)) (injected nil))
    (while (and (< (float-time) deadline) (not (file-exists-p stop)))
      (accept-process-output nil 0.2)
      (sleep-for 0.1)
      (when (and (not injected) inject (file-exists-p inject))
        (setq injected t)
        (with-current-buffer buf
          (goto-char (point-max))
          ;; A frame satisfying bridge's looksLikePrompt: ❯ selector + a
          ;; line-anchored numbered option + proceed vocabulary.
          (insert "\nDo you want to proceed?\n❯ 1. Yes\n  2. No\n"))))))
ELISP

RT_DIR="$TMP" RT_SESSION="$SESSION" RT_DAEMON="$HOME_DIR/.bridge/daemon.json" \
RT_TYPED="$TYPED" RT_INJECT="$INJECT" RT_STOP="$STOP" \
  emacs --batch -Q -L "$ROOT" -l "$ROOT/magnus-bridge.el" -l "$CLIENT_EL" \
  >"$EMACS_LOG" 2>&1 &
EMACS_PID=$!

# --- python helpers over /local/contacts -----------------------------------
contacts() { curl -s "${LOCAL_AUTH[@]}" "$BASE/local/contacts"; }
# field <name> <key>: read a contact's field from a contacts JSON on stdin
cfield() { python3 -c 'import json,sys
name,key=sys.argv[1],sys.argv[2]
try: data=json.load(sys.stdin)
except Exception: sys.exit(0)
cs=data.get("contacts") if isinstance(data,dict) else data
for c in cs or []:
    if c.get("name")==name:
        v=c.get(key); print("" if v is None else v); break' "$1" "$2"; }

# --- assertion (i): the agent is live on the remote transport, flavor emacs --
live=n
for _ in $(seq 40); do
  if [ "$(contacts | cfield wolf-sim status)" = "live" ]; then live=y; break; fi
  sleep 0.25
done
if [ "$live" = y ]; then ok "wolf-sim registered live via the emacs client"
else bad "wolf-sim never went live"; echo "--- emacs.log ---"; cat "$EMACS_LOG"; echo "--- server.log ---"; tail -30 "$LOG"; fi

C=$(contacts)
[ "$(printf '%s' "$C" | cfield wolf-sim transport)" = "remote" ] \
  && ok "wolf-sim uses the remote transport" \
  || bad "wolf-sim transport is not 'remote'"
[ "$(printf '%s' "$C" | cfield wolf-sim transport_flavor)" = "emacs" ] \
  && ok "wolf-sim carries the emacs flavor" \
  || bad "wolf-sim flavor is not 'emacs'"

RCID=$(printf '%s' "$C" | cfield wolf-sim id)
[ -n "$RCID" ] && ok "resolved wolf-sim contact id ($RCID)" || bad "no contact id for wolf-sim"

# --- pair a device so we can drive the phone send API ----------------------
CODE=$(curl -s "${LOCAL_AUTH[@]}" -X POST "$BASE/local/pair" | sed -n 's/.*"code":"\([0-9]*\)".*/\1/p')
PAIR_BODY="{\"code\":\"$CODE\",\"device\":\"itest\"}"
DEVICE_TOKEN=$(curl -s -o /dev/null -D - "${J[@]}" -d "$PAIR_BODY" "$BASE/api/pair" \
  | grep -i 'set-cookie:.*bridge_token=' | sed -n 's/.*bridge_token=\([0-9a-f]*\).*/\1/p' | head -n1)
DEV_AUTH=(-H "Authorization: Bearer $DEVICE_TOKEN")
[ -n "$DEVICE_TOKEN" ] && ok "paired a device token" || bad "device pairing failed"

# --- assertion (ii): a phone send lands in the buffer, exactly once ---------
NONCE="BRIDGEXHELLOX7F3"
SEND_BODY="{\"agent\":\"$RCID\",\"text\":\"$NONCE\"}"
curl -s -o /dev/null "${DEV_AUTH[@]}" "${J[@]}" -d "$SEND_BODY" "$BASE/api/send"
landed=n
for _ in $(seq 40); do
  if [ -f "$TYPED" ] && grep -q "$NONCE" "$TYPED"; then landed=y; break; fi
  sleep 0.25
done
if [ "$landed" = y ]; then ok "phone send typed into the agent buffer (via the client's drain loop)"
else bad "phone send never reached the buffer"; echo "--- typed.log ---"; cat "$TYPED" 2>/dev/null; echo "--- emacs.log ---"; cat "$EMACS_LOG"; fi

# Wait past ack_timeout(2s)+ttl(3s): if the ack stuck, the daemon never
# redelivers, so the frame is typed exactly once.
sleep 6
COUNT=$(grep -c "$NONCE" "$TYPED" 2>/dev/null || echo 0)
if [ "$COUNT" = "1" ]; then ok "delivery acked — typed exactly once, no redelivery"
else bad "expected exactly one delivery, got $COUNT (ack may not have stuck)"; fi

# --- assertion (iii): attested dialog tail flips prompt_open (phase-3) ------
touch "$INJECT"
flipped=n
for _ in $(seq 24); do
  if [ "$(contacts | cfield wolf-sim prompt_open)" = "True" ]; then flipped=y; break; fi
  sleep 0.25
done
if [ "$flipped" = y ]; then
  ok "attested dialog tail flipped prompt_open (phase-3 raise present)"
else
  bad "attested dialog tail did not raise a prompt card"
  echo "--- diag: contacts ---"; contacts
  echo "--- diag: emacs.log tail ---"; tail -25 "$EMACS_LOG"
  echo "--- diag: server.log tail ---"; tail -25 "$LOG"
fi

# --- stop the client, report -----------------------------------------------
touch "$STOP"
echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
