#!/bin/sh
# Live check for GitHub issue #1 (ledger §A3 `AN EMPTY NAME ANSWER GETS LMS'S NAME BACK`): does
# SqueezeDSP engage on a LyrionPlay player? Plays the player's CURRENT queue entry (the queue is not
# changed), polls `squeezedsp.status` until its pipeline runs or 15 s pass, then stops it if it is still
# that play (a play started meanwhile is left alone). An empty queue does nothing.
# MAKES SOUND: ask Simon which player first. Does nothing unless the player is stopped.
#   sh scripts/tests/live_name_sdp.sh <player mac> [lms]      (lms: http://plex:9000)
set -u
MAC=${1:?usage: live_name_sdp.sh <player mac> [lms]}
LMS=${2:-http://plex:9000}

rpc() {
	curl -s -m 10 -H 'Content-Type: application/json' \
		-d "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$MAC\",$1]}" "$LMS/jsonrpc.js"
}
field() { python3 -I -c "import json,sys; r=json.load(sys.stdin)['result']; print($1)"; }

mode=$(rpc '["status","-","1"]' | field "r.get('mode')")
[ "$mode" = stop ] || { echo "the player is '$mode', not stopped: nothing done"; exit 2; }
index=$(rpc '["status","-","1"]' | field "'' if r.get('playlist_cur_index') is None else r['playlist_cur_index']")
[ -n "$index" ] || { echo "the queue is empty: nothing done"; exit 2; }
name=$(rpc '["status","-","1"]' | field "r.get('player_name')")
echo "player '$name', playing queue entry $index"
rpc "[\"playlist\",\"index\",\"$index\"]" >/dev/null
# what this play is, so the stop at the end is only ever its own (/code-review 2026-11-23 finding 8)
ours=$(rpc '["status","-","1"]' | field "(r.get('playlist_cur_index'), r.get('playlist_timestamp'))")

i=0 running=0 status='' mode=''
while [ "$i" -lt 15 ]; do
	sleep 1
	i=$((i + 1))
	status=$(rpc '["squeezedsp.status"]')
	running=$(printf '%s' "$status" | field "r['status'].get('pipeline',{}).get('running',0)")
	mode=$(rpc '["status","-","1"]' | field "r.get('mode')")
	[ "$running" = 1 ] && break
done
echo "after ${i}s: mode $mode, SqueezeDSP pipeline running=$running"
printf '%s' "$status" | field "json.dumps(r['status'].get('pipeline'))[:600]"
now=$(rpc '["status","-","1"]' | field "(r.get('playlist_cur_index'), r.get('playlist_timestamp'))")
mode=$(rpc '["status","-","1"]' | field "r.get('mode')")
if [ "$now" = "$ours" ] && [ "$mode" = play ]; then
	rpc '["stop"]' >/dev/null
	echo "stopped: $(rpc '["status","-","1"]' | field "(r.get('mode'), r.get('playlist_cur_index'))")"
else
	echo "not stopped: the player is '$mode' on $now, no longer this script's play ($ours)"
fi
