# Live test with the output tap (what reached the DAC)

Moved verbatim from CLAUDE.md.

Used for the 0.2.8, 0.2.9 and 0.2.10 live tests (§C). The suite proves a rule; this shows the
frames the real device got.
1. Ask Simon which player and device. Check the player's mode before every LMS command, and note
   the queue to put back.
2. Since 0.4.0 the agent runs one engine per player that is on, each with its own
   `~/Library/Application Support/LyrionPlay/players/<slug>/engine.pid` (`follow` for *Follow the
   macOS output*, `Paths.slug` of the UID for a device) and its own `engine-<slug>.log`. Read every
   `players/*/engine.pid` FIRST (the agent deletes each as it stops that engine), then
   `launchctl bootout gui/$(id -u)/com.crystalgipsy.lyrionplay.agent` and check that each of those
   PIDs has exited.
3. Run the INSTALLED engine by hand on the arguments of agent.log's last "engine N of <player name>
   started:" line for the player under test, never another player's (not `ps`: squeezelite splits `-a 0:1` in place, so `ps` shows it mangled), with a scratch log
   for `-f` and the PID captured at launch:
   `sh -c 'echo $$ > DIR/engine.pid; exec env LYRIONPLAY_TAP=DIR/tap /Applications/LyrionPlay.app/Contents/MacOS/squeezelite <args>'`
4. Drive LMS over JSON-RPC (`playlistcontrol cmd:load track_id:N`, `stop`) and watch the engine
   log. A command meant to land inside an open goes out on the `device rate N Hz` line: the FiiO's
   relock leaves ~0.7 s before `opened`. `track start` can be logged before `opened`.
   Rig tracks: DSD64 827020, DSD256 827002, 44.1k FLAC 816519 (The Roots), 192k 795396.
5. The tap is one file per open, `DIR/tap-NNN-<rate>Hz.f32`, interleaved Float32 left/right.
   Classify each frame by its 32-bit word (float x 2^31): 0 is PCM silence; a top byte of 0x05 or
   0xFA with 0x6969 below it is DoP silence, with anything else below it DoP music; any other value
   is PCM. `tools/bitcheck` compares a tap with a reference decode for bit-exactness. The tap shows
   what CoreAudio took, not what the DAC played: on 2026-10-11 the FiiO took every frame of four
   plays and Simon heard none of them. What is HEARD needs Simon at the DAC, told before each play.
6. `kill` only the captured PID, then
   `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.crystalgipsy.lyrionplay.agent.plist`.
   Check agent.log ("agent started", "LMS: using …"), that the player is connected in LMS, and
   that the queue is as it was.
