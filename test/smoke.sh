#!/usr/bin/env bash
# Smoke test: boot magnus-bridge in batch Emacs against the magnus stub,
# then exercise the API surface with curl.
set -euo pipefail

cd "$(dirname "$0")/.."
DIR="$(mktemp -d)"
MB=http://127.0.0.1:8399

if lsof -nP -iTCP:8399 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "FAIL: port 8399 already in use (stale test server?)"; exit 1
fi
# $EMACS may be a wrapper script; kill its children too or the real
# emacs survives and squats on the port for the next run.
trap 'pkill -P "$SERVER_PID" 2>/dev/null || true; kill "$SERVER_PID" 2>/dev/null || true; rm -rf "$DIR"' EXIT

MB_TEST_DIR="$DIR" "${EMACS:-emacs}" -Q --batch -L . -L test \
  -l magnus-stub -l magnus-bridge -l test/run-server.el \
  >"$DIR/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 40); do
  grep -q "test server ready" "$DIR/server.log" 2>/dev/null && break
  sleep 0.25
done
grep -q "test server ready" "$DIR/server.log" || {
  echo "FAIL: server did not start"; cat "$DIR/server.log"; exit 1; }

pass=0; fail=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); echo "ok   - $1"
  else
    fail=$((fail + 1)); echo "FAIL - $1 (expected $2, got $3)"
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

CODE=$(cat "$DIR/pair-code")
# Bodies are precomputed: macOS bash 3.2 mis-parses \" escapes inside
# a double-quoted $(...) and brace-expands the JSON into fragments.
PAIR_BODY="{\"code\":\"$CODE\",\"device\":\"smoke\"}"
REPLAY_BODY="{\"code\":\"$CODE\",\"device\":\"replay\"}"
J=(-H "Content-Type: application/json")

check "app shell served"        200 "$(code $MB/)"
check "api rejects unpaired"    401 "$(code $MB/api/status)"
check "bad pairing code"        403 "$(code "${J[@]}" -d '{"code":"000000"}' $MB/api/pair)"
check "path traversal blocked"  404 "$(code --path-as-is $MB/../magnus-bridge.el)"
check "pairing succeeds"        200 "$(code -c "$DIR/cookies" "${J[@]}" \
  -d "$PAIR_BODY" $MB/api/pair)"
check "code is single-use"      403 "$(code "${J[@]}" \
  -d "$REPLAY_BODY" $MB/api/pair)"
check "status with token"       200 "$(code -b "$DIR/cookies" $MB/api/status)"
check "send delivers"           200 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"stub-1","text":"smoke hello"}' $MB/api/send)"
check "send by name"            200 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"test-fox","text":"name addressing works"}' $MB/api/send)"
check "offline contact 409"     409 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"ghost-agent","text":"anyone home?"}' $MB/api/send)"
check "duplicate send dropped"  200 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"stub-1","text":"dup test","client_id":"cid-1"}' $MB/api/send)"
dup=$(curl -s -b "$DIR/cookies" -H "Content-Type: application/json" \
  -d '{"agent":"stub-1","text":"dup test","client_id":"cid-1"}' $MB/api/send)
case "$dup" in
  *'"duplicate":true'*) pass=$((pass + 1)); echo "ok   - retry acked as duplicate" ;;
  *) fail=$((fail + 1)); echo "FAIL - duplicate not flagged: $dup" ;;
esac
check "empty send rejected"     400 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"stub-1","text":"  "}' $MB/api/send)"
check "approve needs flag"      400 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"stub-1","key":"1"}' $MB/api/approve)"
check "approve key whitelist"   400 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"stub-1","key":"q"}' $MB/api/approve)"

history=$(curl -s -b "$DIR/cookies" "$MB/api/history?since=0")
case "$history" in
  *'"text":"smoke hello"'*) pass=$((pass + 1)); echo "ok   - history has sent event" ;;
  *) fail=$((fail + 1)); echo "FAIL - history missing sent event: $history" ;;
esac

sse=$(curl -s -N -b "$DIR/cookies" --max-time 2 "$MB/api/events?since=0" || true)
case "$sse" in
  *'"type":"sent"'*) pass=$((pass + 1)); echo "ok   - SSE replays backlog" ;;
  *) fail=$((fail + 1)); echo "FAIL - SSE backlog missing: $sse" ;;
esac

# Reply streaming: the send above armed a watch on the stub session file.
# Append an assistant line with thinking + text; only the text may relay.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"secret reasoning"}]}}' >> "$DIR/sess-test.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"On it, boss."}]}}' >> "$DIR/sess-test.jsonl"
sleep 2.5
history=$(curl -s -b "$DIR/cookies" "$MB/api/history?since=0")
case "$history" in
  *'"type":"reply"'*'On it, boss.'*) pass=$((pass + 1)); echo "ok   - reply streamed from session file" ;;
  *) fail=$((fail + 1)); echo "FAIL - reply not streamed: $history" ;;
esac
case "$history" in
  *'secret reasoning'*) fail=$((fail + 1)); echo "FAIL - thinking block leaked to phone" ;;
  *) pass=$((pass + 1)); echo "ok   - thinking blocks not relayed" ;;
esac

# Typing indicator: session-file growth with NO visible text must yield
# a transient typing event on the live SSE stream (and never in history).
curl -s -N -b "$DIR/cookies" --max-time 4 "$MB/api/events?since=999" >"$DIR/sse-live" &
SSE_PID=$!
sleep 0.5
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' >> "$DIR/sess-test.jsonl"
wait "$SSE_PID" || true
if grep -q '"type":"typing"' "$DIR/sse-live"; then
  pass=$((pass + 1)); echo "ok   - typing event on live stream"
else
  fail=$((fail + 1)); echo "FAIL - no typing event: $(cat "$DIR/sse-live")"
fi
history=$(curl -s -b "$DIR/cookies" "$MB/api/history?since=0")
case "$history" in
  *'"type":"typing"'*) fail=$((fail + 1)); echo "FAIL - typing event leaked into history" ;;
  *) pass=$((pass + 1)); echo "ok   - typing events not stored" ;;
esac

# Upload: 4KB of fake JPEG bytes, base64'd. Server must save the file
# and nudge the agent with its path.
FAKE_IMG=$(head -c 4096 /dev/urandom | base64 | tr -d '\n')
UPLOAD_BODY="{\"agent\":\"stub-1\",\"text\":\"look at this\",\"image\":\"$FAKE_IMG\"}"
check "upload accepted"            200 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d "$UPLOAD_BODY" $MB/api/upload)"
if ls "$DIR"/attachments/photo-*.jpg >/dev/null 2>&1; then
  pass=$((pass + 1)); echo "ok   - photo saved to attachments dir"
else
  fail=$((fail + 1)); echo "FAIL - no photo file written"
fi
check "garbage upload rejected"    400 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"agent":"stub-1","image":"!!!"}' $MB/api/upload)"

check "pattern too short rejected" 400 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"action":"add","pattern":"rm"}' $MB/api/patterns)"
check "pattern learned"            200 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"action":"add","pattern":"Bash(git status)"}' $MB/api/patterns)"
patterns=$(curl -s -b "$DIR/cookies" "$MB/api/patterns")
case "$patterns" in
  *'Bash(git status)'*) pass=$((pass + 1)); echo "ok   - pattern listed" ;;
  *) fail=$((fail + 1)); echo "FAIL - pattern missing from list: $patterns" ;;
esac
check "pattern removed"            200 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"action":"remove","pattern":"Bash(git status)"}' $MB/api/patterns)"
check "unknown pattern remove"     400 "$(code -b "$DIR/cookies" "${J[@]}" \
  -d '{"action":"remove","pattern":"never-existed-xyz"}' $MB/api/patterns)"

# History must be repeatable: reading it twice returns the same events
# (regression: destructive nreverse on shared list structure emptied the
# history a little more on every page refresh).
h1=$(curl -s -b "$DIR/cookies" "$MB/api/history?since=0")
h2=$(curl -s -b "$DIR/cookies" "$MB/api/history?since=0")
case "$h1" in *'smoke hello'*) ok1=y ;; *) ok1=n ;; esac
case "$h2" in *'smoke hello'*) ok2=y ;; *) ok2=n ;; esac
if [ "$ok1$ok2" = "yy" ]; then
  pass=$((pass + 1)); echo "ok   - history is repeatable"
else
  fail=$((fail + 1)); echo "FAIL - history not repeatable (1st=$ok1 2nd=$ok2)"
fi

# History must survive a server restart (persisted to history.jsonl).
pkill -P "$SERVER_PID" 2>/dev/null || true
kill "$SERVER_PID" 2>/dev/null || true
for _ in $(seq 20); do
  lsof -nP -iTCP:8399 -sTCP:LISTEN >/dev/null 2>&1 || break
  sleep 0.25
done
: > "$DIR/server.log"
MB_TEST_DIR="$DIR" "${EMACS:-emacs}" -Q --batch -L . -L test \
  -l magnus-stub -l magnus-bridge -l test/run-server.el \
  >"$DIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 40); do
  grep -q "test server ready" "$DIR/server.log" 2>/dev/null && break
  sleep 0.25
done
h3=$(curl -s -b "$DIR/cookies" "$MB/api/history?since=0")
case "$h3" in
  *'smoke hello'*) pass=$((pass + 1)); echo "ok   - history survives restart" ;;
  *) fail=$((fail + 1)); echo "FAIL - history lost after restart: $h3" ;;
esac

echo "----"
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
