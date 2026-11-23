#!/bin/sh
# (c) 2026 CrystalGipsy, for LyrionPlay. MIT.
#
# Runs scripts/tests/live_name_sdp.sh against a stand-in LMS on 127.0.0.1 (no player, no sound), for
# /code-review 2026-11-23 finding 8: an empty queue does nothing; the stop at the end is sent only
# while the player is still on the play the script started. Prints one line per case; exit 0 only if
# all pass.
#   sh scripts/tests/live_name_sdp_offline.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d) || exit 1
pid=''
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$WORK"' EXIT

cat > "$WORK/lms.py" <<'EOF'
# a stand-in for LMS's /jsonrpc.js: the player's status per case, every command logged
import http.server, json, sys
case, log = sys.argv[1], sys.argv[2]
state = {"played": False, "reads_after": 0, "stopped": False}
def status():
    if case == "empty":
        return {"mode": "stop", "player_name": "Test"}
    if not state["played"]:
        return {"mode": "stop", "playlist_cur_index": "2", "playlist_timestamp": 100.5, "player_name": "Test"}
    state["reads_after"] += 1
    # "changed": a new play (another queue) starts once the script has noted its own
    ts = 200.5 if case == "changed" and state["reads_after"] > 1 else 100.5
    return {"mode": "stop" if state["stopped"] else "play", "playlist_cur_index": "2", "playlist_timestamp": ts, "player_name": "Test"}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        cmd = body["params"][1]
        with open(log, "a") as f: f.write(" ".join(map(str, cmd)) + "\n")
        if cmd[0] == "status": result = status()
        elif cmd[0] == "squeezedsp.status": result = {"status": {"pipeline": {"running": 1}}}
        elif cmd[0] == "playlist": state["played"] = True; result = {}
        elif cmd[0] == "stop": state["stopped"] = True; result = {}
        else: result = {}
        out = json.dumps({"id": 1, "result": result}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
EOF

passed=0 total=0
check() { # check <case> <expected exit> <grep for the log: sent or not> <yes|no>
	total=$((total + 1))
	: > "$WORK/log"
	port="$WORK/port.$total"   # a file of its own per case: never the last case's port
	python3 -I "$WORK/lms.py" "$1" "$WORK/log" > "$port" &
	pid=$!
	i=0; while [ ! -s "$port" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
	if [ ! -s "$port" ]; then
		kill "$pid" 2>/dev/null; pid=''; echo "FAIL  $1: the stand-in LMS did not start in 30 s"; return
	fi
	out=$(sh "$ROOT/scripts/tests/live_name_sdp.sh" 02:00:00:00:00:01 "http://127.0.0.1:$(cat "$port")" 2>&1)
	rc=$?
	kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; pid=''
	if grep -qx "$3" "$WORK/log"; then sent=yes; else sent=no; fi
	# every case must have reached the stand-in: a case that never did would pass on "not sent"
	if grep -qx "status - 1" "$WORK/log" && [ "$rc" = "$2" ] && [ "$sent" = "$4" ]; then
		passed=$((passed + 1)); echo "PASS  $1: exit $rc, '$3' sent: $sent"
	else
		echo "FAIL  $1: exit $rc (want $2), '$3' sent: $sent (want $4)"; printf '%s\n' "$out" | sed 's/^/        /'
	fi
}

check empty 2 "playlist index None" no
check same 0 "stop" yes
check changed 0 "stop" no
echo "live_name_sdp offline: $passed of $total passed"
[ "$passed" -eq "$total" ]
