# LyrionPlay — native macOS slimproto player

## Project overview
A Squeezebox player for the Mac that Lyrion Music Server treats like any other squeezelite.
It is built for macOS:

- exclusive (hog) access and per-track sample-rate switching on an external DAC, so playback
  is bit-perfect;
- DSD as DoP;
- LMS replay gain;
- LMS volume, chosen per player: the device's own volume (the Mac's volume or the DAC's
  hardware volume, both ways), software where the Mac can't set the device's volume, or Fixed on a
  DAC (LyrionPlay sets LMS's pref;
  a DAC whose volume the Mac sets holds the level LMS had, `FIXED HOLDS THE LMS VOLUME`);
- one player per output (`ONE PLAYER PER DAC`, built 2026-10-12): *Follow the macOS output*, and
  one for each other device, each its own squeezelite and its own LMS player.

It runs as a background launchd agent, switched on and off from a menu bar app, signed with
the hardened runtime.

Three parts in one app bundle:

| part | language | licence | job |
|---|---|---|---|
| `engine/` | C | GPLv3 | squeezelite fork plus the new `output_coreaudio.c` |
| agent (`app/Sources/Agent`) | Swift | MIT | probes devices, builds each player's engine arguments, supervises one engine per player that is on |
| menu bar app (`app/Sources/App`) | Swift | MIT | On/Off, each player's status, the player list (switch + cog) and settings |

The approved plan, with phases and verification, is `~/.claude/plans/whimsical-bouncing-dawn.md`.
Started 2026-10-09 under a working title. Named **LyrionPlay** by Simon on 2026-10-09 ("change it
across everything so no refs" to the old one): every name in this file, the code and the paths
is the new one, including entries written before the rename.

## Layout
```
deps/build-cmake.sh   builds CMake 4.4.4 from source into deps/tools (Apple Silicon only)
deps/build-deps.sh    static arm64 codec libraries into deps/out (Phase 1)
engine/               squeezelite at a pinned commit (UPSTREAM.md) + output_coreaudio.c
app/                  SwiftPM package: PlayerCore library, Agent, App, tests
tools/bitcheck        compares the engine's output tap with a reference decode
tools/icon            make-icon: renders the app icon from app/Resources/LyrionPlay.svg
tools/make_readme_html.py   README.md + INSTALL.md -> README.html, INSTALL.html, index.html
                      (the fleet's generator, adapted; version badge from VERSION)
VERSION               the one place the version is set (build.sh and the pages read it)
scripts/bump-version.sh  raises VERSION (patch by default; minor, major) and regenerates the pages
scripts/build.sh      deps -> engine -> swift build -> regression suite -> icon -> bundle ->
                      ad-hoc sign -> checks; stops if a codec build or a test fails;
                      --install runs install.sh on it; --release checks the codec archives
                      against their SHA-256 straight after the codec build, before anything
                      else is built, then makes TWO zips, both attached
                      to the release: dist/LyrionPlay-<v>-codec-sources.zip, then
                      dist/LyrionPlay-<v>.zip (A RELEASE CARRIES ITS SOURCE)
scripts/test.sh       the regression suite (REGRESSION SUITE): engine conversion, engine output
                      against a fake HAL (engine/tests/test_output_coreaudio.c, linked with
                      upstream's output.c, with the SCENARIO MATRIX), swift test,
                      install.sh in a sandbox (scripts/tests/test_install.sh). No device, app,
                      keychain or server is touched
scripts/install.sh    what every user runs: own certificate, unquarantine, sign, install
scripts/uninstall.sh  removes the app, agent, settings, logs (--remove-certificate too)
INSTALL.md            the user-facing install guide, shipped in the release zip with INSTALL.html
```
`deps/src`, `deps/tools`, `deps/out`, `build/`, `.build/` and `dist/` are git-ignored.

## Working rules for this repo
- **Before any test that makes sound,** ask Simon which output device to use.
- **Changing the device's or LMS's volume counts as a test that makes sound.** Check the player's
  mode before EVERY change, never only at the start (2026-10-10: a dB probe ran while Simon had
  started playing, and briefly set his speakers to several levels, up to 0 dB).
- **The LMS rig is `http://plex:9000`** (LMS 9.1.2, server name "Simons Music"). Slimproto is `plex:3483`.
- **Kill only a PID you captured at launch.** Never `pkill` by pattern.
- **No virtual audio drivers** (BlackHole etc.). Audio tests run on Simon's USB DAC.
- **No Homebrew.** Tools are built locally for Apple Silicon.
- **Never commit, push or tag without being asked, and never prompt or offer to.**

## Live test with the output tap (what reached the DAC)
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

## Review Ledger — READ THIS BEFORE REPORTING ANY FINDING

The workspace `CLAUDE.md` one level up holds the three fleet-wide gates. This ledger holds what
is settled for THIS project. Review and fix happen in separate sessions, so a decision, a
disproven belief or a cleared finding that is not written here will be re-reported as a finding.

### DECLINED / SETTLED INDEX — GREP THIS FIRST, BY SYMBOL

| symbol / subject | verdict | find it with |
|---|---|---|
| engine choice: squeezelite fork vs a Swift rewrite | **DECIDED by Simon 2026-10-09**: fork, plus a native CoreAudio output | `THE ENGINE IS A SQUEEZELITE FORK` |
| signing: self-signed identity, no notarisation; Developer ID / Apple fees; who holds the key | **DECIDED by Simon 2026-10-09**: shared; EACH USER signs their own copy with their own certificate (install.sh). Never re-propose the Developer Program or a shared certificate | `EACH USER SIGNS IT` |
| app name, icon | **DECIDED by Simon 2026-10-09**: LyrionPlay; icon A (Material play arrow leading into Lyrion's waveform) | `LYRIONPLAY AND ICON A` |
| run mode: menu bar app plus a launchd agent (SMAppService) | **DECIDED by Simon 2026-10-09** | `MENU BAR PLUS AGENT` |
| menu app and player lifetimes; `MenuPresence`, `menu.lock`, `ensureMenu`, `LaunchAgent.stop`/`startIfOn` | **DECIDED by Simon 2026-10-09**: tied, separate processes | `THE MENU AND THE PLAYER ARE TIED` |
| Apple Silicon only, macOS 14+ | **DECIDED by Simon 2026-10-09** | `APPLE SILICON ONLY` |
| BlackHole or any virtual audio driver for tests | **DECLINED by Simon 2026-10-09** | `NO VIRTUAL AUDIO DRIVERS` |
| CMake.app (universal) / Homebrew | **DECLINED by Simon 2026-10-09**: CMake built from source | `TOOLS ARE BUILT HERE` |
| `MaxSampleRate` capped at 384000 (`-Z`) | by design, from the LMS source | `THE 384K CAP` |
| DoP off by default, per device | by design: macOS cannot report it | `DOP IS A SWITCH` |
| `CanHTTPS` not advertised, no OpenSSL | by design | `NO HTTPS IN THE ENGINE` |
| the spike uses the real bundle id and agent label | by design | `THE SPIKE IS THE REAL IDENTITY` |
| On/Off via SMAppService | **WRONG with a self-signed identity** (§A3); replaced by a classic `~/Library/LaunchAgents` plist plus `launchctl` | `SMAPPSERVICE PINS THE FIRST BUILD` |
| locating sibling executables from `argv[0]` | **WRONG** under SMAppService (§A3); use `Bundle.main` | `ARGV0 IS BUNDLE-RELATIVE` |
| "the agent's Local Network approval covers the programs it starts" | **WRONG** (§A3): each executable asks once | `EACH EXECUTABLE ASKS ONCE` |
| "LMS can be told the DAC's rate list" | **WRONG** (§A3) | `NO RATE LIST` |
| `set_volume` with LMS fixed volume (`output.volume_fixed`) leaves the device level alone | by design; differs from `output_alsa.c` `-V` | `FIXED VOLUME LEAVES THE DEVICE ALONE` |
| Fixed on a DAC with a volume control holding LMS's saved volume, not 0 dB as upstream; Material showing fixed at 100 meanwhile; `-a <f>:<e>:<x>:<h>`, `ca.fixed`, `ca.hold`, `put_held_level`, `HeldVolume`, `PlayerSettings.heldVolume`, `chooseVolume`; Fixed ignoring LMS's level in the engine whatever `adjust` says | **DECIDED by Simon 2026-10-12, BUILT the same day, INSTALLED as 0.4.0**, NOT live-tested (§A2) | `FIXED HOLDS THE LMS VOLUME` |
| settings.json from 0.3.x (no `version` 2) moved to settings-0.3.json and replaced by the defaults | **BY DESIGN, Simon 2026-10-12** ("no migration needed"; `Settings.setAsideOlder`); a version-2 file is never set aside (`SETTINGS CARRY OVER FROM 0.4.0 ON`) | `ONE PLAYER PER DAC` |
| 0.3.x's `mac` and `player-name` taken over by *Follow the macOS output* (`PlayerIdentity.adoptOldPlayer`, `Paths.oldMAC`/`oldPlayerName`), so the 0.3.x LMS player carries on; device players are new LMS players | **DECIDED by Simon 2026-10-12** ("Keep the old ID"); my earlier row here called new MACs for every player "BY DESIGN, Simon" from "no migration needed", which was about SETTINGS: WRONG, corrected | `THE OLD PLAYER CARRIES ON` |
| "Fixed at 100%" per DAC; `VolumeMode.fixed`, `FixedVolumeSync` (`checked`/`recordRefusal`, was `sent`), `syncFixedVolume`, `playerpref digitalVolumeControl`, `PlayerState.digitalVolumeControl`; LyrionPlay putting back a fixed/variable setting made in LMS or Material | **BUILT 2026-10-11, DECIDED by Simon** ("LyrionPlay, per DAC"): LyrionPlay OWNS the pref, both ways; **INSTALLED as 0.3.0** 2026-10-11, the put-back in 0.3.1; the switch BOTH WAYS **VERIFIED LIVE 2026-10-12** on the DragonFly (agent.log + LMS); still owed: a change made in Material put back, the FiiO on 0.3.1, the DragonFly's level after a switch (§B) | `FIXED AT 100% PER DAC` |
| "a `digitalVolumeControl` set from outside takes effect only at the next track" | **WRONG** (§A3): LMS sends an audg at once | `SETTING DVC SENDS AN AUDG AT ONCE` |
| "changing `digitalVolumeControl` leaves the player's volume alone"; `volumeRestore`, LMS volume 0 after a switch back from Fixed; a user's slider move between `volumeRestore`'s two reads undone | **WRONG** (§A3): LMS's hook saves a faded (temporary) volume; the slider-move window ACCEPTED (§A2 `FIXED AT 100% PER DAC`, "Volume put back"; re-reported by /code-review 2026-10-12 (4)); FOUND LIVE 2026-10-11 (50 -> 0), FIXED (put back), **INSTALLED as 0.3.1, VERIFIED LIVE 2026-10-12** both ways on the DragonFly (§B) | `THE DVC HOOK SAVES A FADED VOLUME` |
| "`mixer volume ?` answers the temporary volume while LMS fades" | **WRONG** (§A3): it reads the saved pref | `MIXER VOLUME ? IS THE SAVED VOLUME` |
| `ioproc` stops taking frames at a rate-change boundary; `slimproto.c` clears `ca_reopen` BEFORE `_ca_open` | by design; both differ from the PortAudio path | `THE BOUNDARY AND THE REOPEN FLAG` |
| agent restart leaving a second engine; `stopOrphanedEngine`, `engine.pid` | **FIXED 2026-10-09** (§A3) | `A CRASHED AGENT ORPHANS ITS ENGINE` |
| SwiftUI `@State` in the menu app | **WRONG with the Command Line Tools** (§A3): state lives in `PlayerModel` | `NO SWIFTUI MACROS WITHOUT XCODE` |
| menu bar icon gone "when playback started"; no ⌘Q in the menu app; `AppDelegate.quitChosen`, `menu.log` | **FIXED 2026-10-09** (§A3): a shortcut quit it, not playback | `A SHORTCUT QUIT THE MENU` |
| `build.sh --install` leaving the player running | **BY DESIGN 2026-10-09**: the player restarts only when the agent or engine cdhash changed, so a menu-app fix doesn't stop the music | `A SHORTCUT QUIT THE MENU` |
| Mac volume -> LMS; `volume_listener`, `vrec`, `lyrionplay:volume`, `deviceVolumeChanged`, `VolumePush`, `LatestValueSender`, `LMSVolume` | **BUILT + MEASURED 2026-10-10** (Phase 5): the engine reports only changes it did not make | `VOLUME BOTH WAYS` |
| a settle window / read-back record in `apply_volume`; tolerance `VOLUME_MOVED_DB` | by design (§A3): the speakers report a level up to 2 dB from the one set | `READ-BACK IS NOT THE LEVEL SET` |
| Mac unmute sending `mixer muting 0`, not a level | by design (§A3) | `UNMUTE IS NOT A LEVEL` |
| version numbers; `VERSION`, `bump-version.sh`, `AppVersion`, CFBundleShortVersionString / CFBundleVersion | **DECIDED 2026-10-10** (Simon: "we should have versioning"): the fleet's yes/no rule | `VERSIONING` |
| GitHub page; README.html / INSTALL.html / index.html | **BUILT 2026-10-10** at Simon's request ("a html page like our fleet") | `PAGES LIKE THE FLEET` |
| DSD256 / DSD512 arrive at the FiiO as PCM | **WRONG to call it a bug** (§A3): DoP needs 705.6k, the FiiO's Mac driver stops at 384k | `DSD256 IS PCM ON THE FIIO` |
| review of the review's fixes, 2026-10-10: `apply_latest`/`apply_lock` (stale level on resume), retry cadence 2/4/5 s + `quiet` logging, `OutputFollow` (follow lost on a restart) | **FOUND IN MY OWN FIXES, FIXED, each with a test that FAILED on the pre-review code** (§C) | `REVIEW OF THE FIXES` |
| review 2026-10-10: findings 1-10 (hog vs "Follow the macOS output", `vrec.lock` deadlock, retry flood + hog kept, push order, extra `mixer volume ?`, fixed volume before the first audg, `volume_pending`, ATS, install.sh menu race, picker/dead code) | **ALL VERIFIED, ALL FIXED, each pinned by a test that fails on the old code** (§C) | `REVIEW 2026-10-10` |
| "macOS leaves its default output alone when a process hogs that device"; `resolveDevice(holding:)`, `OutputFollow` (was `followDeferred`), `heldDevice` | **WRONG** (§A3): it moves away in <10 ms and back on release | `HOG MOVES THE DEFAULT OUTPUT` |
| "AudioObjectRemovePropertyListener returns at once"; `vrec.watch`, `point_listeners` | **WRONG** (§A3): it waits for a call in flight | `REMOVE WAITS FOR THE LISTENER` |
| `NSAllowsLocalNetworking` / `NSAllowsArbitraryLoads` in Info.plist | **MEASURED** (§A3): local covers plain names only, and its presence voids arbitrary | `ATS LOCAL IS PLAIN NAMES ONLY` |
| `swift test` failing with "plugin for module 'TestingMacros' not found"; `-load-plugin-library` in `scripts/test.sh` | **A TOOLCHAIN FLAKE** (§A3), not a test failure | `TESTING MACROS BY NAME` |
| the regression suite: `scripts/test.sh`, `engine/tests/test_output_coreaudio.c` (fake HAL), `scripts/tests/test_install.sh` (shims) | **BUILT 2026-10-10** at Simon's request ("we need a regression suite"); `build.sh` stops on a failure | `REGRESSION SUITE` |
| inline review after 0.2.2: `apply_latest` with a stale device ID, `_ca_open` from two threads, hog re-taken on each retry, `OutputFollow`, `scripts/test.sh` on a fresh checkout; stale doc refs (`followDeferred`, `pushVolume`, `LyrionPlay-0.1.0` paths) | **CLOSED, NO code findings; doc refs FIXED** (§C) | `INLINE REVIEW AFTER 0.2.2` |
| player model name; `EngineArguments.modelName`, `-M`, `ModelName`, Material player icon; the model name differing from the app name (`SqueezeLiteMac` vs `LyrionPlay`), "inconsistent branding" | **BY DESIGN, NOT A FINDING — DECIDED + VERIFIED 2026-10-10** (Simon: "Logo works"; "this isnt a bug or an issue its as planned for the logo to work"): `SqueezeLiteMac`, so Material shows its Apple icon; LMS `model` stays `squeezelite`. Never report the mismatch or propose `LyrionPlay` back | `MODEL NAME IS SqueezeLiteMac` |
| several DACs as several LMS players, each with its own MAC and name; ONE squeezelite for every output, so a change of output inherits LMS's volume and fixed setting; `PlayerSlot`, `EnginePlan`, `PlayerList`, `Settings.players`, `followDevice`, `Paths.player`/`slug`, `PlayerStatus` | **BUILT 2026-10-12** to the approved plan (`~/.claude/plans/immutable-purring-hoare.md`; Simon: "each DAC or output device needs its own Squeezlite instance"); suite PASS; **INSTALLED as 0.4.0** 2026-10-12 19:57Z, NOT live-tested (§B) | `ONE PLAYER PER DAC` |
| "LMS limits DSD to the rates the player takes"; dsf/dff in `convert.conf` | **WRONG** (§A3): passthrough at any rate | `DSD IS PASSTHROUGH AT ANY RATE` |
| "LMS applies replay gain"; `canDoReplayGain`, `next_replay_gain` | **WRONG** (§A3): the player applies it, from `strm` | `THE PLAYER APPLIES REPLAY GAIN` |
| "bit-perfect needs volume-code changes"; `_apply_gain`, `FIXED_ONE` | **WRONG** (§A3): squeezelite already skips the gain at unity and for DoP/DSD | `BIT-PERFECT IS ALREADY HANDLED` |
| "upstream squeezelite already does hog mode / `-V` on macOS"; `output_pa.c` | **WRONG** (§A3): PortAudio only; `-V`/`-X` are ALSA-only | `NO HOG MODE UPSTREAM` |
| "macOS can say whether a DAC takes DoP" | **WRONG** (§A3): CoreAudio has no DoP property | `NO DOP PROPERTY IN COREAUDIO` |
| "DoP needs exclusive mode"; DoP off or greyed out under *Follow the macOS output* / Exclusive off (`set_physical_format` only when `ca.hogged`) | **WRONG** (§A3, Simon on the FiiO 2026-10-14): DoP works in shared mode | `DOP WORKS WITHOUT EXCLUSIVE MODE` |
| "Local Network approval is lost on every rebuild" | **WRONG** (§A3): it is tied to the certificate leaf | `APPROVAL SURVIVES A REBUILD` |
| "BSD sockets are blocked under launchd" (Apple FB16131937) | **NOT REPRODUCED** (§A3) on macOS 26.7.1 | `FB16131937 NOT REPRODUCED` |
| "LMS sends one volume on resume"; `fade_volume`, `_Resume`, `audg` | **WRONG** (§A3): an `audg` every 0.05 s while it fades in | `RESUME IS ONE AUDG` |
| "LMS sends the volume as soon as a player connects" | was logged WRONG; that verdict is itself **WRONG, MEASURED 2026-10-14**: LMS sends its saved level ~5 ms after every connect AND reconnect (§A3) | `LMS SENDS VOLUME ON CONNECT` |
| "a universal binary depends on Rosetta" | **WRONG** (§A3) | `UNIVERSAL IS NOT ROSETTA` |
| /code-review after 0.2.2 (2026-10-10): `ServerChoice`/`refreshLMS` (a check begun before a server change), `monitor_opening`/`output_close_coreaudio` (close while the monitor opens); `rotate` comment; status.json every 2 s, blocking `LMSDiscovery.find`, `menuLog` duplicating `Log` | **1, 3, 4 VERIFIED + FIXED, each pinned by a test that FAILED on the old code; 1 and 3 VERIFIED LIVE (0.2.5); 7 prose FIXED; 6, 8, 9 CLEARED** (§C); 2 and 5 §A3 | `CODE-REVIEW AFTER 0.2.2` |
| "LMS mute leaves a `-V` DAC audible at its minimum"; `apply_volume` with no `kAudioDevicePropertyMute` | **NO WRITER** (§A3): every device here with a volume control has a mute | `MUTE HAS A WRITER ONLY WITHOUT A MUTE CONTROL` |
| "the monitor's 100 ms poll while the output is off costs energy"; `OFF_POLL_US` | **WRONG** (§A3, measured) | `THE OFF POLL COSTS NOTHING MEASURABLE` |
| play from idle switching the DAC's rate twice (`_ca_open` opens at `current_sample_rate`); `_rate_ok`, `_track_pending`, `TRACK_WAIT_POLLS` | **CONFIRMED in engine.log, FIXED 2026-10-10** (§C, Simon: "build the fix with care"); 0.2.3 opened at the pending rate (live: works when the decoder is first, 2 of 4); the capped WAIT for the decoder DECIDED by Simon, INSTALLED 0.2.4, one switch per play VERIFIED LIVE on the DragonFly and the FiiO (§B) | `TWO RATE SWITCHES AT PLAY` |
| "Silence on a rate change" (`rateSwitchDelayMs`, `-r …:<ms>`, `output.rate_delay`) STRETCHED on a play from idle by the rate fix; `delay_active` | **FOUND 2026-10-11 in my own fix (0.2.3/0.2.4), FIXED (Simon: "look to fix the silence setting problem"), INSTALLED 0.2.5, VERIFIED LIVE on the FiiO** (§B) | `RATE DELAY STRETCHED AT PLAY` |
| a STALLED or slow LMS server: any finding that needs LMS to stall or answer late (`refreshLMS`, `ServerChoice`, `lmsCheckRunning`, `lastLMSCheck`, `LMSDiscovery.find`, `LMSClient.call` timeouts, a check outlasting the 2 s tick or the 5 s cadence) | **NOT A FINDING — DECIDED by Simon 2026-10-11** ("as we cant test a stale server note to skip this in reviews as it will be fixed if and when it ever comes up"): skip it in reviews; fixed if it ever happens live. agent.log lines show one (0.2.7) | `A STALLED SERVER IS NOT A FINDING` |
| the FORMAT of silence (DoP silence or PCM zeros) when stopped, paused, buffering, around an open or at the idle release (`_silence_fmt`, `ca.track_rate`/`ca.track_fmt`, `silencebuf_dsd`, the OFF branch, `_ca_open`); "the DAC flips to PCM / clicks / loses its DSD lock" | **NOT A FINDING — DECIDED by Simon 2026-10-11** ("Ive tested myself swithcing to pretty much most formats no silence its not needed so why we doing this? switch fine. Why are we messing with this silence when stopped or paused?"): skip it in reviews. Its premise, squeezelite's "DSD silence keeps the DAC locked", was never tested on the FiiO. Still a bug: DoP silence at a PCM rate (a buzz: round 1's fix stays) and anything heard on the DAC (§A2) | `SILENCE FORMAT IS NOT A FINDING` |
| /code-review 2026-10-11 of 0.2.3-0.2.5: DoP silence at a PCM rate (`_silence_fmt`, `outfmt`, `silencebuf_dsd`); the rate delay mark lost on a flush / left set by a stop during the open (`_mark_switch_done`, `delay_active`); a flushed `track_start` read as pending (`_track_pending`, `_buf_used`, `_rate_ok`); `_start_delay` copying output.c; agent: a dropped check waiting 5 s, `playerState` outside `ServerChoice` | **1, 2, 6, 7 VERIFIED + FIXED; 3 VERIFIED in a variant (the reviewer's own path does not occur) + FIXED; 5 pinned in UPSTREAM.md, not a shared helper; each fix pinned by a test that FAILED on the old code; INSTALLED as 0.2.6 2026-10-11 09:39Z (Simon: "bump and install"); DSD<->PCM from idle and finding 3 VERIFIED LIVE on the FiiO; 2 not reachable live there (8-10 ms window)** (§C) | `CODE-REVIEW 2026-10-11` |
| /code-review 2026-10-11 (2) of 0.2.6-0.2.7: agent.log `took N s` per check for a host that does not answer, no server line at start / after a setting change (`LMSCheckLog`, `refreshLMS`); `_silence_fmt` at the LAST track's rate (play from idle, synced start); the test fake's pause frames and `OUTPUT_START_AT` not written through `write_cb`; a slow+dropped check's two lines; the pending-rate predicate written three times | **ALL 6 VERIFIED + FIXED** (1-4 first, then 5-6 on Simon's "yes"); 1-5 each pinned by a test that FAILED on the old code (1 measured: 6.0 s a check); 6 a refactor (`_at_pending_rate`) pinned by a mutant; also a slow run misattributed after a setting change (my own round-1 code) FIXED; **INSTALLED as 0.2.8** 2026-10-11 14:15Z (agent restart + server line seen live; findings 1+3 LIVE: one line each for a dead server; finding 2's window does not occur with local files, tap: music from frame 0 in 4 of 4 plays) (§C) | `CODE-REVIEW 2026-10-11 (2)` |
| inline review after CODE-REVIEW 2026-10-11 (2): `LMSCheckLog` threading, `ended`/`settingChanged`, `_silence_fmt` pending-first in every output state, the fake's `OUTPUT_PAUSE_FRAMES`/`OUTPUT_START_AT`, `reopen()` straight after `start()` in a test; the build's `SendableClosureCaptures` warning (`Supervisor` in `refreshLMS`); stale refs (`scripts/test.sh` header, "the way to see one") | **CLEARED; one wording nit FIXED** ("quick again" also ended a run with a quick FAILURE; now "back under 4 s", Simon: "yes"); doc refs FIXED (§C) | `INLINE REVIEW 2026-10-11` |
| /code-review 2026-10-11 (3) of 0.2.8: `_silence_fmt` after `output_flush` resets `current_sample_rate` (`error_opening`) with `outfmt` still DOP (now `ca.track_rate`/`ca.track_fmt`); the test `flush` lacking that rule (UPSTREAM.md); `LMSCheckLog.timed` run ended by a quick check of another target, a plain 4 s timeout on the `> 4` line (now the server's answer over 2 s, `slowAnswer`), the control `eachChangeOfServerOnce` at took 4.0; `refreshLMS` timing with wall-clock `Date()` (now `SuspendingClock` in the task); `End.kept(server:)` + `found` redundant (now `kept(answered:)`) | **ALL 6 VERIFIED + FIXED 2026-10-11** (Simon: "verify and fix … we need to be more thorough here"); the engine suite now links upstream's `output.c` and runs a ~25,700-scenario matrix (`SCENARIO MATRIX`); **INSTALLED as 0.2.9** 2026-10-11 15:53Z; finding 1 VERIFIED LIVE 17:13 (tap: PCM zeros after a stop inside the 44.1k open after DSD64; §C); the live test's own find, `THE IDLE RELEASE'S LAST CALL WAS ZERO`, FIXED + INSTALLED as 0.2.10 18:33Z, VERIFIED LIVE 19:36 (tap: DoP silence to the close); one belief CLEARED there (a synced start goes OFF -> `OUTPUT_START_AT`) | `CODE-REVIEW 2026-10-11 (3)` |
| the engine suite's scenario matrix (`matrix` in `tests/test_output_coreaudio.c`, `check_invariants`, `run_scenario`, `MATRIX_ONE`/`MATRIX_FIND`/`MATRIX_ALL`); upstream `output.c`/`buffer.c`/`output_pack.c`/`dop.c` linked into the suite instead of hand copies | **BUILT 2026-10-11** in CODE-REVIEW 2026-10-11 (3) (Simon: "we seem to be getting repeated regressions with the rate change and silence, we need to be more thorough"); catches every silence/rate bug the reviews found, on the engine that had it, and 10 of 10 mutants (§C); since the 0.2.9 live test also the idle release's last call (`THE IDLE RELEASE'S LAST CALL WAS ZERO`: `boundary_pad` no longer covers an OFF call) | `SCENARIO MATRIX` |
| /code-review 2026-10-11 (4) of 0.2.9-0.2.10: `ca.track_rate`/`ca.track_fmt` outliving the idle release (DoP silence after a PCM play stopped at a released DoP track's rate); `dsd_format track_fmt` outside `#if DSD`; the `Duration.seconds` extension; `ended(_:found:answer:took:)` taking both times; the OFF-branch comment ("the last call", "what played") | **ALL 5 VERIFIED; 2-5 FIXED; 1 fixed, then REVERTED 2026-10-11 on Simon's decision** (`SILENCE FORMAT IS NOT A FINDING`): the engine plays frame for frame as 0.2.10 (`MATRIX_SIG` diff, 25,690 scenarios, 0 differ). DAC test on the FiiO: Simon heard none of the scenario plays though the FiiO took every frame; the FiiO dropped off USB at 21:21:27 (not investigated, Simon: "leave investigating this"). NOT installed. CLEARED: the OFF branch's `_output_frames` is no use-after-free; the track-start record sees a rate delay's second half; `.kept(answered:)`/`checked` pairing and a run carried across servers (§C) | `CODE-REVIEW 2026-10-11 (4)` |
| /code-review 2026-10-11 (5) of the tree after round 4 (test tooling only; NO engine/agent finding): `matrix()` counting a failed `fork()` (pid -1 slot, `waitpid` ECHILD, unset `status`); `scripts/test.sh` reporting a failed conversion suite as "died first" (`^conversion:`); `write_sig` silent on `fopen` failure, `MATRIX_ONE` writing none; the signature without the track or the samples ("frame for frame") | **ALL 4 VERIFIED + FIXED 2026-10-11** (Simon: "fix the toolings"), each anti-run against a copy of the old tooling; the engine is 0.2.10's machine code (`otool -tV`: only log `__LINE__` constants differ). DROPPED at the gates: the OFF comment naming `_silence_fmt` in a non-DSD build (no writer: the Makefile always sets DSD; `SILENCE FORMAT IS NOT A FINDING`), stalled-server log lines (§C) | `CODE-REVIEW 2026-10-11 (5)` |
| "the matrix is frame-deterministic" (diffing `MATRIX_SIG` output between builds) | **NARROWER** (§A3): synced starts (170 scenarios) slip a call under the parallel load, and some even run alone; every other scenario is exact | `THE MATRIX IS FRAME-EXACT BUT ONE` |
| "the agent.log `took N s` line (0.2.7-0.2.8, whole check over 4 s) shows a stalled server" | **WRONG** (§A3): only a request with no answer could cross it | `THE 4 S LINE SAW ONLY TIMEOUTS` |
| "a stop inside the open leaves the delay mark for a later album" (CODE-REVIEW 2026-10-11 finding 3's path) | **NARROWER** (§A3): the next album's own strm q clears it, unless the output went off between | `A NEW ALBUM'S FLUSH CLEARS THE MARK` |
| "the engine starts with its device absent and waits for it" (`volume_pending`, REVIEW 2026-10-10 finding 7) | **ONLY WITH -r** (§A3): without a rate delay, `output_init_common` exits on `test_open` | `AN ABSENT DEVICE AT START EXITS THE ENGINE` |
| the menu's output line showing DoP's PCM rate (176.4 kHz) for DSD64; `ca_report_format`, `lyrionplay:format`, `FormatReport`, `FormatLine` (`lyrionplay:format idle`, since CODE-REVIEW 2026-10-12), `AgentStatus.dsdRate`, `DeviceCaps.dsd`, `engineFormat` | **BUILT 2026-10-11** (Simon: "when playing DSD the helper app shows the PCM rate when its DoP this should show the DSD Rate"); suite PASS, **INSTALLED as 0.2.11** 2026-10-11 22:03Z, **VERIFIED LIVE by Simon** ("it works correctly") (§B) | `DSD RATE IN THE MENU` |
| volume choices a device offers; `VolumeMode.isOffered`/`offered(by:)`/`nearestOffered(on:)` (was `offered(on:)`), `Settings.options(for:)`, the LMS volume picker; Fixed on the speakers / Bluetooth / AirPlay / HDMI; "Device's own volume" on a device with no volume control | **DECIDED by Simon 2026-10-12**: device volume only with a control, Fixed only on a DAC (`isExternal`); a blocked choice already saved is read as the nearest offered; since 2026-10-14 Software only without a control (`SOFTWARE ONLY WITHOUT A VOLUME CONTROL`) | `ONLY WHAT A DEVICE OFFERS` |
| Settings window buttons; "Save and Close", `dismissWindow`, `PlayerModel.save` returning Bool, `saveError` | **BUILT 2026-10-12 at Simon's request** ("can we add a save and close option as well as save"); INSTALLED 0.3.5, **VERIFIED LIVE by Simon** ("works") | `SAVE AND CLOSE` |
| /code-review 2026-10-12 of 0.2.11-0.3.1: Fixed caption "the Mac's volume keys set it" (hog moves the default output); the "louder" warning keyed on `device.volume == nil` (now `VolumeMode.scalesSamples`, `volumeCaption`); `dsdRate` after the idle release (now `FormatLine`, `lyrionplay:format idle`); `_ = await client.call` (send result ignored); `volumeRestore` with a failed read; `lastLMSCheck` after a settings change; `ca_report_format`'s second lock; the redundant `lastLMSCheck = .distantPast`; the format test's statics; stale ledger lines; the `fixedVolume` lock comment | **ALL 11 CHECKED 2026-10-12** (Simon: "verify all of them before recommending fixing"): 2, 3 VERIFIED + FIXED (each pinned: anti-run / mutant); 6, 10, 11 VERIFIED, prose FIXED; 1 CONFIRMED by Simon (the keys act on the macOS output only), wording FIXED, CLOSED (§B); 4, 5 DROPPED (`A STALLED SERVER IS NOT A FINDING`); 7, 8 DECLINED; 9 WRONG (§A3). **INSTALLED as 0.3.2** 2026-10-12 09:05Z, NOT live-tested (§C) | `CODE-REVIEW 2026-10-12` |
| the menu's format report straight after a reopen (`ca_report_format` saying the last track's `ca.track_rate`/`ca.track_fmt`, "176400 dop" for a PCM track after the idle release, `said_open`); the idle-release test replaying the same DSD64; ANY lag of the report or the menu behind the DAC (the "every ~100 ms" comment, `wait_readwake(ehandles, 1000)`, no `wake_controller` at a same-rate gapless start: up to ~1 s) | **NOT A FINDING — DECIDED by Simon 2026-10-12** ("this is how dacs work the change will happen when output hits the dac not before"; on the lag, /code-review (6): "I dont care about the lag"): the report follows what reaches the DAC, and a new track's format reaches it only at its start. Skip it in reviews | `THE FORMAT CHANGES WHEN OUTPUT HITS THE DAC` |
| /code-review 2026-10-12 (2) of 0.3.2-0.3.5: findings 1+2 above; `VolumeMode.scalesSamples(deviceHasVolume:)` dead branch + the `.device` "falls back to software" comment; Revert / `onAppear` leaving `saveError`/`lastError` (`PlayerModel.revert`, `clearSaveError`); `lyrionplay:volume` lines from a replaced engine sent to LMS (`self.engine === process`) | **1, 2 DECLINED by Simon** (above); **3, 4, 5 VERIFIED + FIXED 2026-10-12** (Simon: "Verify the rest and look to fix"); suite PASS; 4 and 5 not covered by a suite (app UI / agent main); **INSTALLED as 0.3.6** 2026-10-12 10:13Z, not live-tested (§C) | `CODE-REVIEW 2026-10-12 (2)` |
| "each engine test shares one process, so a test that keeps static state passes only when it runs first" | **WRONG** (§A3): `main` forks every test | `EACH ENGINE TEST IS ITS OWN PROCESS` |
| "a `playerpref` set answers no result, so `call` returns nil for it"; "status's `mixer volume` is the temporary (faded) volume" | **WRONG** (§A3, measured / LMS 9.1 source 2026-10-12) | `A SET ANSWERS AN EMPTY RESULT` |
| "the engine ignores SIGPIPE (`stream.c`), so its stdout lines (`lyrionplay:format`, `lyrionplay:volume`) are harmless after the agent dies" | **WRONG** (§A3, source 2026-10-12): an orphan dies at its next line; not a defect | `AN ORPHAN DIES AT ITS NEXT REPORT` |
| "a mid-play reopen for a rate change makes `ca_report_format` print a stray `lyrionplay:format idle`" (`_ca_open` clears `ca.dev` and unlocks) | **WRONG** (§A3, source 2026-10-12, /code-review 2026-10-12 (4)) | `NO STRAY IDLE ON A REOPEN` |
| "LMS fixes the level at the volume set before switching to fixed"; `digitalVolumeControl` 0, `audg` `adjust`, `process_audg`, `FIXED_ONE`, the DragonFly's level in Fixed varying | **WRONG** (§A3, LMS 9.1 + squeezelite source, 2026-10-12): fixed is a flag, the player plays at 100% | `LMS FIXED IS A FLAG, NOT A LEVEL` |
| "a probe sees no volume control on a device another process holds exclusively"; `settable()`, `DeviceCaps.probe` / `squeezelite -l` while the engine holds the DAC | **WRONG** (§A3, measured on the DragonFly 2026-10-12) | `A HOG DOES NOT HIDE THE VOLUME CONTROL` |
| /code-review 2026-10-12 (3) of 0.2.10-0.3.6: a reconcile probe while the engine holds the DAC turning a saved "Device's own volume" into Software (`options(for:)`, `-V`); `PlayerModel.save` writing the corrected choice for every listed device; `formats[nformats - 1]` in the format tests' messages; `FixedVolumeSync.sent` (now `recordRefusal`); `offered(by:)`/`offered(on:)` (now `nearestOffered(on:)`) | **1, 2 DISPROVEN 2026-10-12** (Simon: "verify 1 & 2 hold up under real world tests"): the hold does not hide the volume control (§A3), so neither has a writer; **3, 4, 5 VERIFIED + FIXED**; suite PASS; **INSTALLED as 0.3.7** 2026-10-12 10:53Z (§C) | `CODE-REVIEW 2026-10-12 (3)` |
| docs pass of 0.3.7: README.md, INSTALL.md, NOTICES.txt, engine/UPSTREAM.md, the pages, build.sh's header, this file's overview/layout/install log; full licence texts of the bundled libraries not in the app | **DONE 2026-10-12** (Simon: "do a pass on all docs to ensure nothings missing or reported incorrecly"); UPSTREAM.md VERIFIED exact against the pinned archive; the licence texts BUILT (Simon: "yes"), INSTALLED as 0.3.10 (§C) | `DOCS PASS 2026-10-12` |
| licence compliance for a release: the 15 texts in `licences/`, `NOTICES.txt` (version stamped by build.sh), the source tag `v<version>`, `LyrionPlay-<version>-codec-sources.zip`, copyright lines in the files written for LyrionPlay, UPSTREAM.md's 5(a) notice | **BUILT 2026-10-12** (Simon: "update all accordingly we need this to be correct"); what a release must carry is in §A2 | `A RELEASE CARRIES ITS SOURCE` |
| /code-review 2026-10-12 (4) of 0.2.10-0.3.11: the codec-sources zip copied unchecked (`build.sh --release`, `fetch`, `.built-*` stamps); `volumeRestore` undoing a slider move; `DeviceCaps.dsd` "22.5 MHz" / "3.0 MHz" (`dsdLabels`); the `fixedVolume` comment's `sent`; the soxr licence loop | **ALL 5 VERIFIED 2026-10-12** (Simon: "verify all 5"): 1, 4, 5 FIXED (Simon: "fix them"); 2 a REPEAT (accepted, §A2); 3 FIXED (Simon: other users' DACs reach it): the full rate, "DSD64 (2.8224 MHz)"; **INSTALLED as 0.3.12** (§C) | `CODE-REVIEW 2026-10-12 (4)` |
| /code-review 2026-10-12 (5) of 0.2.10-0.3.12: `build-deps.sh \| tail -15` hiding a failed codec build (also `make-icon`'s `\| grep … \|\| true`); `--release` writing the app zip before the codec-source checks (`check_codec_sources`, `codec_pins`); `ca_report_format`'s `!rate` guard unpinned, and its two `fflush(stdout)` (`CHECK_FLUSHED`, `fake_fflush`); the layout line's one zip; `volumeAfter`'s dead `?? "?"` | **ALL 5 VERIFIED + FIXED 2026-10-12** (Simon: "fix them all ensure no regressions check all carriers for the core audio"); a 14-mutant sweep of the engine code new since the last push: 14 of 14 killed after the flush pin; build.sh new vs old in an APFS clone; **INSTALLED as 0.3.13** (§C) | `CODE-REVIEW 2026-10-12 (5)` |
| /code-review 2026-10-12 (6) of 0.2.10-0.3.13: a good `PlayerModel.save` wiping a switch-on error in `lastError`; the release stepper at 0 (`idleSeconds`, no `-C`) and the Exclusive caption; build.sh's "before anything is built" comment + the Layout line; the "every ~100 ms" report cadence; cleared: `digital_volume_control` in `status`, `-f` stderr only, `codec_pins` on macOS awk/shasum, the pages vs their `.md` | **1-3 VERIFIED + FIXED 2026-10-12** (Simon: "fix those"); **4 DISMISSED by Simon** ("I dont care about the lag", `THE FORMAT CHANGES WHEN OUTPUT HITS THE DAC`); suite PASS; **INSTALLED as 0.3.14** with the docs; fixes 1 and 2 VERIFIED LIVE by Simon (1 staged) (§C) | `CODE-REVIEW 2026-10-12 (6)` |
| /code-review 2026-10-12 (7) of 0.2.10-0.3.14: a `-V` DAC switched to Fixed or Software while paused, left muted at `db_min` by LMS's pause fade (`EngineArguments` `-V`, `apply_volume`'s `kAudioDevicePropertyMute`, `fixedVolumeNeverTouchesTheDevice`); the idle release and the exit leaving that mute (`output_close_coreaudio`, `unhog`); a failed save then a good one losing a switch-on error (`lastError`, `saveError`, `clearSaveError`); `nearestOffered(on:)` repeating `DeviceOptions.defaults(for:)`'s volume default | **1 CONFIRMED by Simon** ("1 does happen"); two fixes BUILT, then REVERTED by Simon the same day (a put-back at exit; Fixed putting the DAC at 100%): the cause is one LMS player for every output, so the requirement moved to `ONE PLAYER PER DAC` (§B `FIXED SET UP WHILE PAUSED`); Software's case a KNOWN LIMITATION (§A2 `SOFTWARE AFTER A PAUSED -V DAC`); **3 DISMISSED** (§A2 `SAVE AND CLOSE`); 4 not answered; tree back at 15fa252 (§C) | `CODE-REVIEW 2026-10-12 (7)` |
| the one-player-per-output build and the held Fixed (engine `-a` fields, PlayerCore v2, agent `PlayerSlot`, app player list + cog), its tests, mutants and matrix diff | **BUILT 2026-10-12**, suite PASS, **INSTALLED as 0.4.0**, live checks owed (§C) | `PLAYERS AND FIXED BUILT 2026-10-12` |
| Mac slider -> Material lag under *Follow the macOS output*; a Bluetooth headset's slider never reaching LMS (`volume_listener`, `VOLUME_SETTLE_NS`, `apply_volume`, `LatestValueSender`) | **reported by Simon 2026-10-14, CLOSED the same day**: the lag's cause MEASURED (LMS's echo put back on the device + the settle window) and FIXED, INSTALLED as 0.4.2, VERIFIED LIVE (§C `THE DEVICE STAYS WHERE THE MAC PUT IT`; the first fix, `LMS'S ECHO IS NOT PUT ON`, rejected); the lag left is LMS's status debounce, a faster-following push pace DECLINED by Simon ("leave it and close this"): NOT A FINDING; the headset's cause MEASURED and FIXED, INSTALLED as 0.4.1 (§C `A STUCK DB PROPERTY FIXED`) | `MAC SLIDER LAG AND THE BLUETOOTH HEADSET` |
| `lms_echo`, `echo_reported`, `echo_forget`, `ECHO_DB` (1.1 dB): an audg within 1.1 dB of a reported level skipped | **BUILT then REJECTED by Simon 2026-10-14** (a Material nudge within 5 s not heard), **REPLACED in the tree** by `THE DEVICE STAYS WHERE THE MAC PUT IT`; never built into the app (§C) | `LMS'S ECHO IS NOT PUT ON` |
| a Mac level move while LMS is muted; `VolumeReport.levelMoved`, the report's `<moved>` field, `VolumePush` (`mixer muting 0` only for an unmute alone); LMS's fade-out after a Mac mute unmuting the device per step | the move **CONFIRMED + FIXED by Simon's decision 2026-10-14, INSTALLED as 0.4.2, VERIFIED LIVE** ("all works"); the fade-out **ACCEPTED by Simon** (not a finding) (§C, §B) | `A MAC MOVE UNMUTES LMS AT ITS LEVEL` |
| `put_lms_level`, `lv` (`lv_for`, `lv_reported`, pair, held, fresh), `lms_gain`, `agent_volume`, `restore_pair`, `ECHO_NS`; LMS's answer to a report recognised by its exact gain; a level LMS sends again (connect, stream start, twin) not put on; a resume ending on the Mac's exact scalars; the first level at an engine start taken as the device is | **DECIDED by Simon 2026-10-14** ("yes" to the design, after "verify this will work with out any other issues or volume snapping to another volume at track or album change"), **BUILT** the same day, suite PASS, **INSTALLED as 0.4.2, VERIFIED LIVE by Simon** ("all works"); a Mac -> Material lag remains (§B) (§C) | `THE DEVICE STAYS WHERE THE MAC PUT IT` |
| `read_device_db`'s stuck rule (`scalar_to_db`; a dB reading at the top of its range with the scalar below 1.0 read through ScalarToDecibels); the fake HAL's `stuck_db`, `chan_volume`, `curved_conversion`, serial `notify` | **BUILT 2026-10-14** (Simon: "okay check over all areas this would hit and be sure to doument thoroughly"); **INSTALLED as 0.4.1**, VERIFIED LIVE by Simon the same day ("it works", with the lag: §C `LMS'S ECHO IS NOT PUT ON`) (§C) | `A STUCK DB PROPERTY FIXED` |
| "the HAL's dB property always follows the volume"; "ScalarToDecibels equals the dB property" (`read_device_db`, `kAudioDevicePropertyVolumeDecibels`, `kAudioDevicePropertyVolumeScalarToDecibels`) | **WRONG, both** (§A3, measured 2026-10-14) | `A DB PROPERTY CAN BE STUCK` |
| "a `mixer volume` reaches Material at once"; `statusQuery_filter`, `LatestValueSender(interval: 0.15)`, Material standing still during a Mac drag | **WRONG** (§A3, measured 2026-10-14): LMS debounces status 0.3 s per volume change, restarted by each; ~0.5 s per change is LMS's floor. A 350 ms push pace (Material follows a drag) **DECLINED by Simon 2026-10-14**: the remaining lag is NOT A FINDING | `LMS DELAYS STATUS FOR A VOLUME CHANGE` |
| a player switched to Fixed inside a sync group not shown as fixed in Material until regrouped | **UNVERIFIED, stood down by Simon 2026-10-14** (§B) | `SYNC GROUP: FIXED NOT SHOWN IN MATERIAL` |
| switching *Device's own volume* to *Software* while paused leaves a DAC with a volume control muted at its minimum | **KNOWN LIMITATION, NOT FIXING — Simon 2026-10-12** (§A2); unreachable since 2026-10-14 (no Software on such a device) | `SOFTWARE AFTER A PAUSED -V DAC` |
| *Software* on a device with a volume control (`VolumeMode.isOffered`, `.software`); one choice for *Follow the macOS output*; removing Fixed from such DACs too, Fixed set by hand in LMS | **DECIDED by Simon 2026-10-14**: Software only where the device has no volume control; a saved Software there read as its own volume; Fixed KEPT (the paused traps were put to him first); **INSTALLED as 0.4.3** (§A2) | `SOFTWARE ONLY WITHOUT A VOLUME CONTROL` |
| Fixed for *Follow the macOS output* (`VolumeMode.isOffered` `.fixed`, `follow:`); "MacOS 2 options" | **DECIDED by Simon 2026-10-14**: offered only while Follow plays to a DAC with no volume control (the FiiO), never a held level; **INSTALLED as 0.4.4, VERIFIED LIVE** (§A2) | `FIXED ON FOLLOW, NO-CONTROL DACS ONLY` |
| the Mac's volume keys / menu bar slider doing nothing to a DAC held in Exclusive mode (*Follow the macOS output* or a device player) | **AS INTENDED, Simon 2026-10-14**: macOS moves its output away from a held device; the keys note says "with Exclusive mode off" (§A2) | `THE MAC'S VOLUME AND EXCLUSIVE MODE` |
| LMS's slider doing nothing to DSD sent as DoP on a *Software* player (`dopCaption`, upstream `output.c` FIXED_ONE for non-PCM) | **NOT A BUG**, said on screen at Simon's request 2026-10-14, **INSTALLED as 0.4.4, VERIFIED LIVE** (§A2) | `DOP PLAYS AT FULL LEVEL` |
| the picker's *Fixed at 100%* label (`Text("Fixed")`, INSTALL.md); LMS's own "Output level is fixed at 100%" | **DECIDED by Simon 2026-10-14**: the choice is *Fixed* (it holds LMS's level on a DAC with a volume control); LMS's setting keeps its own name; **INSTALLED as 0.4.3** (§A2) | `FIXED, NOT FIXED AT 100%` |
| inline review of 0.4.0-0.4.2 (15fa252..b6b929f): `PlayerModel.save` / the switch / the cog writing *Follow the macOS output*'s volume as its device of the moment offers it (`Settings.forSaving`); the Fixed caption's "turn it down before saving" (`volumeCaption`, INSTALL.md) | **1 VERIFIED + FIXED 2026-10-14** (Simon: "yes fix that"), pinned + 2 mutants; **2 FIXED by Simon's wording** ("just remove the turn it down bit all is correct up to that"); **INSTALLED as 0.4.3**, not live-tested (§C) | `INLINE REVIEW 2026-10-14` |
| `PlayerSettings.init(from:)`, `Settings.read` (`.older`, `.unreadable`), `setAsideOlder`: a 0.4.x settings.json read by a later build | **DECIDED by Simon 2026-10-14**: carried over, never reset; only 0.3.x's set aside (§A2) | `SETTINGS CARRY OVER FROM 0.4.0 ON` |
| "`Host.current().localizedName` stalls" (`PlayerSettings.macName`, read per `Settings()` decode and per unsaved device row) | **WRONG** (§A3, measured 2026-10-14) | `THE MAC'S NAME LOOKUP STALLS` |
| "a status check holds up a volume push" (`LMSClient.playerStates`, `status` per player in turn) | **WRONG** (§A3, source 2026-10-14) | `A STATUS CHECK HOLDS UP A PUSH` |
| /code-review 2026-10-14 of 0.2.10-0.4.5 (7faf2f8..682cab2): a settings file that did not decode set aside (`Settings.read`); a rename saved while off (`PlayerIdentity.applyName`, `settings-name`, was `ensureNameFile`); Follow switched off while deferred (`OutputFollow.resolve`); Fixed's held level off LMS's gain (`HeldVolume.dB`, `LMSVolume.gain`); engines stopped one at a time (`stopEngines`); the tap procedure's `engine.pid`; `macName`; serial `playerStates` | **1-4, 6, 8 VERIFIED + FIXED 2026-10-14** (Simon: "Verify the rest and look to fix"; 1 for 0.4.0 on only), 5 mutants killed, suite PASS; **5, 7 CLEARED** (§A3); not built (§C) | `CODE-REVIEW 2026-10-14` |
| /code-review 2026-10-15 of the CODE-REVIEW 2026-10-14 fixes (tree): an unreadable settings.json at agent start renaming Follow (`applyName`, `loadSettings`); a version above 2 saved back unchanged (`Settings.read`, `save`); `applyName`'s two writes; the 0.3.x comment in `Settings.read`; `stopping` appended twice in `reconcile` | **1, 2, 4 VERIFIED + FIXED 2026-10-15** (Simon: "verify them all and look to fix check for all carriees and callers"), plus the 0.3.x cut-off off `currentVersion` (`firstPlayersVersion`, found in the carrier audit); 7 mutants killed; suite PASS; **3, 5 CLEARED** (3 measured: the next call repairs it, no writer; 5: a no-op repeat, comment added); not built | `CODE-REVIEW 2026-10-15` |
| the player name file's writers; the agent writing settings.json's names to it (`applyName`, `settings-name`, `saved:`, `settingsRead` are GONE); `PlayerIdentity.createNameFile`/`writeName`/`renameReached`, `Settings.renames(since:devices:)` | **DECIDED 2026-10-15** (my design, on Simon's "Saving settins should not be so complicated"): two writers only, Settings' Save for a Name typed there and squeezelite for an LMS rename; the agent only makes a missing file (§A2) | `THE NAME FILE HAS TWO WRITERS` |
| /code-review 2026-10-15 (2) of the 2026-10-15 fixes (tree): the defaults' name over a name file when settings.json is missing (`loadSettings`, `settingsRead`); the app's Save over an unreadable file; names past squeezelite's 63 bytes or blank (`fitName`); the engine's `<lms>` -1 comment; `applyName`'s `saved:`; the duplicated settings adopt in `run`/`tick`; `chooseVolume`'s inline MAC parse (`PlayerIdentity.mac(at:)`) | **ALL 7 VERIFIED + FIXED 2026-10-15** (Simon: "review this area thorouhgly … Verify and fix all"); 1, 5, 6 by removing the agent's name writing (`THE NAME FILE HAS TWO WRITERS`); 6 mutants killed; suite PASS; not built | `CODE-REVIEW 2026-10-15 (2)` |

### HOW TO LOG A VERDICT so the next round finds it
Every new decision goes in §A2 (declined or by design), §A3 (a belief a measurement killed), §B
(open, accepted, parked or unverified) or §C (closed).
- Write it as a bullet (§A3: a table row) whose FIRST LINE names the symbols a future review
  would grep for, then the verdict, the date and who decided. A §A3 row opens with a CAPS name.
- Add a row to the index in the same edit, ending with a phrase that greps to the entry. Every
  §A3 row gets one: a review reads the index, not §A3, and re-derives an unindexed belief.
- State the reason as a fact that can be DISPROVEN.
- A finding cleared on evidence during a review is logged in the same session; "checked and
  cleared" in a review's prose is lost when the round ends.

Closing a round is not a suppression: a fix records that one defect, as described, was fixed. A
finding about behaviour the fix introduced is new.

### A. NOT FINDINGS — deliberate, fleet-wide
The workspace `CLAUDE.md` Gate 1 applies in full. The rows that arise here:
- The folder is a git repository since 2026-10-11 (Simon: "commit and push to dev"; first push
  `7faf2f8` on `dev`, `main` still the initial README). As in the fleet: uncommitted = under review,
  unpushed = review not passed; a review's scope is the last dev push..HEAD plus the tree. Rounds
  before 2026-10-11 (5) were scoped by file times. Never prompt to commit, push, tag or ship.
- A `dist/` release zip older than `VERSION`: it is made only by `build.sh --release`.
- An entry §B marks UNVERIFIED, not yet live-tested or PARKED: known, not missed.
- A threshold or interval §A2 or §C says was chosen (retry cadence, volume tolerance): a tuning
  call, not a finding.

### A2. NOT FINDINGS — LyrionPlay decisions

- **THE ENGINE IS A SQUEEZELITE FORK — Simon, 2026-10-09.**
  - Protocol, decoders, sync groups, gapless, DSD/DoP and resample-only-when-needed come from
    ralph-irving/squeezelite.
  - The new code is the macOS output, because squeezelite's only Mac output is PortAudio: no hog
    mode, and `-V` hardware volume exists only on ALSA (`main.c` help text, `output_pa.c`).
  - A Swift rewrite was offered and declined: several times the work, and the edge cases
    squeezelite already solved would need rebuilding.
  - The engine is therefore GPLv3; the Swift parts stay MIT, as a separate program in the same bundle.
- **EACH USER SIGNS IT — Simon, 2026-10-09** (the earlier "personal use only" decision is
  superseded).
  - **Shared, but no Apple fees:** "it will be shared but I am not paying apples fees". No
    Developer ID and no notarisation, ever, unless he says otherwise. Never re-propose the
    Developer Program.
  - **Every user signs with their own certificate:** "all users self sign it so its up to them
    not me to keep the key". Never propose a shared release certificate.
  - **The build is signed ad-hoc only.** Apple Silicon runs nothing unsigned.
  - **`scripts/install.sh`**, which the user runs with `sh`:
    - creates "LyrionPlay Signing" in their login keychain the first time, with LibreSSL plus
      `security import -T /usr/bin/codesign`;
    - copies the app to a staging bundle beside the installed one, strips
      `com.apple.quarantine`, signs inside-out with the hardened runtime, and swaps it in;
    - restarts the player only when the agent or engine cdhash changed.
  - **Why approvals survive updates:** the designated requirement is
    `identifier + certificate leaf`, so each user's Local Network approval survives their
    updates. Their key never leaves their Mac.
  - **Signing by name** (`codesign -s "LyrionPlay Signing"`) works for an untrusted
    self-signed identity, so INSTALL.md's by-hand route uses the name.
  - **Measured 2026-10-09 with a throwaway keychain and folder:**
    - a copy with 16 quarantined files was installed with 0 quarantine left;
    - all three executables were signed `Authority=LyrionPlay Test`, `flags=0x10000(runtime)`,
      with the DR `certificate leaf = H"…"`;
    - a second run reused the certificate;
    - no keychain prompt appeared.
  - **Trap:** codesign finds no identity in a keychain outside the user search list, even with
    `--keychain`. The login keychain is always in the list, so only tests hit this.
- **LYRIONPLAY AND ICON A — Simon, 2026-10-09.**
  - **The icon:** the Material Symbols Rounded `play_arrow` (Apache 2.0) takes the place of the
    quiet first five bars of Lyrion's waveform, drawn from lms-material `lyrion-icon.svg` (MIT).
  - **One source, `app/Resources/LyrionPlay.svg`:** the menu bar loads it as a template image
    (`MenuBarIcon`, 16 pt high, alpha 0.4 when the player is off). `tools/icon/make-icon.swift`
    (compiled by build.sh into `build/tools/make-icon`) renders the app icon from it: Lyrion green `#589e81` on Apple's 824/1024 grid, glyph white
    at 62 % width.
  - **Rendering:** macOS 14+ loads SVG natively (`_NSSVGImageRep`, transparent background), so
    no converter is needed.
  - **The four ideas Simon chose from:** A play into the wave, B play beside the wave, C play
    inside the wave, D play button and wave. He said D, then "actually make it A".
- **MENU BAR PLUS AGENT — Simon, 2026-10-09; mechanism CHANGED the same day by the Phase 0 spike.**
  - On = the app writes `~/Library/LaunchAgents/com.crystalgipsy.lyrionplay.agent.plist`
    (`Program` = the agent's absolute path in the installed bundle) and runs
    `launchctl bootstrap gui/$UID <plist>`. Off = `launchctl bootout gui/$UID/<label>` and
    remove the plist. The plist being present is what starts the agent at login.
  - SMAppService was the plan but cannot survive a rebuild with our signature; see
    `SMAPPSERVICE PINS THE FIRST BUILD`.
  - launchd restarts the agent on a crash (`KeepAlive{SuccessfulExit=false}`).
    `ProcessType=Interactive`, so audio is never throttled.
  - **THE MENU AND THE PLAYER ARE TIED — Simon, 2026-10-09** ("they should be tied to one
    another surely?"). They stay separate processes, so a menu crash never cuts the music.
    - **Quit** in the menu boots the agent out before the app exits, and keeps the plist. Any
      orderly quit does this except logout, restart or shutdown (`kAEQuitReason`), when the
      session takes the player down anyway.
    - **Opening the menu** runs `LaunchAgent.startIfOn`.
    - **The agent** opens the menu at login and reopens it if it goes, with backoff from 5 s up
      to 5 min, unless `menu-session-ending` is under a minute old.
    - **Presence:** the menu holds an exclusive `flock` on `menu.lock` for its whole life
      (`MenuPresence`), never a name or path match. A second copy calls `exit(0)` before any UI.
    - **`build.sh --install`** replaces a running menu with SIGKILL, never a quit, because a quit
      stops the player.
    - **Measured 2026-10-09:**
      - the new agent opened the menu 2 s after it started;
      - `kill -9` of the menu: reopened in 1 s, agent and engine PIDs unchanged;
      - `MenuLock` suite: a SIGKILLed holder releases the lock.
    - **Restart VERIFIED 2026-10-10** (Simon rebooted on 0.2.1: "it all restarts on a reboot"):
      menu.log "the session is ending (reason 1919251316)" = `'rest'` at 09:02:25, agent SIGTERM
      1 s later with no menu reopened in between; after boot (10:03 local) the agent started at
      +40 s, the engine on the DragonFly, the menu opened by the agent 3 s later, connected.
    - **UNVERIFIED:** Quit from the panel stopping the player (needs a click); a plain logout
      (same code path, reason `'logo'`/`'rlgo'`, not seen yet).
- **VOLUME BOTH WAYS — Simon reported "volume doesnt appear to be bidirectional", 2026-10-10;
  built the same day.**
  - **Why the engine decides:** only the engine knows which device changes it made itself. A
    watcher in the agent would mistake LMS's mute fades and volume changes for the user's.
  - **Engine (`output_coreaudio.c`):**
    - `vrec` holds the level last applied or reported, in 1/100 dB, plus the mute state;
    - `volume_listener` listens to `VolumeScalar` (main element, or channels 1/2) and `Mute`;
    - it prints `lyrionplay:volume <dB> <muted> <lms>` to stdout only when the device is more than
      `VOLUME_MOVED_DB` (0.6) from the record, or its mute differs. `<lms>` (`vrec.lms`, since
      `REVIEW 2026-10-10`) is LMS's last audg: 1 a level, 0 silence (muted or volume 0), -1 none
      yet;
    - nothing is reported while LMS volume is fixed, or in -X (linear) mode;
    - watching starts at init, from the device's current level, because LMS sends a volume
      only when a track starts.
  - **Since `LMS'S ECHO IS NOT PUT ON` (2026-10-14, in tree):** LMS's answer to a reported level
    (two audgs within 1.1 dB of it) is not put back on the device.
  - **Since `ONE PLAYER PER DAC` (2026-10-12):** all of this is per player. Each engine reports on its
    own stdout; the agent's `PlayerSlot` has its own `LatestValueSender`, MAC and `FixedVolumeSync`.
  - **Agent:**
    - `deviceVolumeChanged` hands each report to a `LatestValueSender`: one push in flight at a
      time, at most one start per 150 ms, the latest level winning (it used to start a detached
      task per push, which could overlap and land out of order);
    - `VolumePush.command` sends `mixer volume LMSVolume.volume(forDB:)`, `mixer muting 1`, or
      `mixer muting 0` when LMS is muted. It asks `mixer volume ?` only when `<lms>` is not 1,
      and `playerpref digitalVolumeControl ?` (0 = fixed, audg's adjust byte) only when it is -1,
      sending nothing to a fixed player;
    - `LMSVolume` is the SqueezePlay curve from the LMS 9.1 source: −74 dB at 0, −37 dB at 25,
      0 dB at 100.
  - **Measured 2026-10-10 on the MacBook Pro speakers, nothing playing:**
    - LMS 50 and LMS 62 stayed put, with 0 reports;
    - Mac 30% gave −28.72 dB → LMS 42, with 1 report;
    - Mac mute → LMS −42 (muted); Mac unmute → LMS 42 and the Mac back at 29%;
    - Simon, playing: "it seems to work ok", with a slight lag that he calls normal (150 ms
      throttle plus Material's redraw).
- **VERSIONING — Simon, 2026-10-10** ("we should have versioning I guess for our builds").
  - **`VERSION` is the only place the version is set,** as x.y.z. `scripts/build.sh` writes it
    into `CFBundleShortVersionString` and the release zip's name. `CFBundleVersion` is the
    build's timestamp, `date +%Y%m%d%H%M`.
  - **`tools/make_readme_html.py`** puts it in the pages' version badge.
  - **`scripts/bump-version.sh [patch|minor|major]`** raises it and regenerates the pages. It
    refuses a malformed VERSION or an unknown argument (tested).
  - **The fleet's rule, from memory `build-and-release-process`:** before every build that is
    handed over or installed, ASK Simon "version up? (yes/no)". Never bump silently, and never
    reuse a number silently. One change out the door = one new number. A fix is a patch, a
    feature is a minor.
  - **Where the version is shown:**
    - the menu panel's footer, "Version x.y.z", with the build in its tooltip (`AppVersion`);
    - the agent's first log line, "agent started: LyrionPlay x.y.z (build)";
    - install.sh, which prints "installing LyrionPlay x.y.z" and "installed … version x.y.z
      (was …)".
  - **The engine's own firmware string** (squeezelite 2.0.0-1609, sent to LMS) is left
    untouched: LMS parses it, for example for its pCP check.
  - **CHANGELOG.md is written at the first release** (the merge to main), per the fleet. Dev
    versions are recorded here.
  - **History:**
    - 0.1.0: every build up to 2026-10-10, covering Simon's first install and the
      volume-both-ways builds.
    - **0.2.0** (Simon: "Yes, 0.2.0", 2026-10-10): volume both ways, the pages and the version
      display. INSTALLED (install.sh: "version 0.2.0 (was 0.1.0)"; agent.log "LyrionPlay 0.2.0
      (202610100038)"). The release is `dist/LyrionPlay-0.2.0.zip`; the old 0.1.0 zip was deleted.
    - **0.2.1** (Simon: "version up", 2026-10-10): the `REVIEW 2026-10-10` fixes and the
      regression suite. INSTALLED 2026-10-10 10:01 (install.sh: "version 0.2.1 (was 0.2.0)",
      player restarted as the agent/engine changed; agent.log "LyrionPlay 0.2.1 (202610101000)";
      connected; one menu, the new copy; no marker left). Simon had moved the player to the
      AudioQuest DragonFly Black v1.5 (USB, with a volume control: `-V`, exclusive) at 09:53.
    - **0.2.2** (Simon: "lets bump the current version as it stands and install it",
      2026-10-10): the three `REVIEW OF THE FIXES` fixes and the model name `SqueezeLiteMac`.
      Suite PASS inside build.sh (engine output 16/16, swift 38 tests, install.sh 3/3).
      INSTALLED 2026-10-10 10:42 (install.sh: "version 0.2.2 (was 0.2.1)"; agent.log "LyrionPlay
      0.2.2 (202610101042)", engine started with `-M SqueezeLiteMac`). LMS `players`: prodmac46
      `96:57:54:14:bd:87`, model `squeezelite`, modelname `SqueezeLiteMac`, connected.
    - **0.3.0** (Simon: "Yes, 0.3.0", a feature so a minor, 2026-10-11): "Fixed at 100%" per DAC
      (`FIXED AT 100% PER DAC`), with 0.2.11's work. INSTALLED 2026-10-11 22:25Z.
    - **0.3.1** (Simon: "build and install" after 0.3.1 was named, 2026-10-12): the volume put-back
      (`THE DVC HOOK SAVES A FADED VOLUME`). INSTALLED 2026-10-12 08:07Z, VERIFIED LIVE.
    - **0.3.2** (Simon: "install", "Yes, 0.3.2", 2026-10-12): the `CODE-REVIEW 2026-10-12` fixes (the
      Fixed warning, the idle release in the menu, the volume-keys wording). INSTALLED 2026-10-12 09:05Z.
    - **0.3.3** (Simon: "build and update", "Yes, 0.3.3", 2026-10-12): the volume-keys wording as Simon
      set it (`THE VOLUME KEYS ON A FIXED DAC`), menu app and INSTALL.md only. INSTALLED 2026-10-12 09:18Z:
      suite PASS inside build.sh, install.sh "version 0.3.3 (was 0.3.2)", the new menu app started 10:18:39
      local; agent and engine NOT restarted (same cdhash, by design), prodmac46 stopped and connected.
    - **0.3.4** (Simon: "install", "Yes, 0.3.4", "Install now" with prodmac46 PAUSED at volume 35, 2026-10-12):
      the non-fixed captions without "fixed", and `ONLY WHAT A DEVICE OFFERS`. INSTALLED 09:43Z: suite PASS
      inside build.sh (engine output 43/43, swift 76, install.sh 3/3); install.sh "version 0.3.4 (was
      0.3.3)"; agent restarted (PlayerCore is in the agent, so its cdhash changed: the player restarted and
      stopped, as told), "agent started: LyrionPlay 0.3.4 (202610121042)", "LMS: using Simons Music";
      LMS connected, stopped, volume 35, `digital_volume_control` 1. The engine's `-a 0:0 -C 10` are
      Simon's own Settings changes at 09:31-09:32Z (Follow the macOS output, the DragonFly's exclusive off,
      release after 10 s), not this build. NOT live-tested: the picker per device.
    - **0.3.5** (Simon: "build and install", "Yes, 0.3.5", 2026-10-12): `SAVE AND CLOSE` and the save error
      in the Settings window; menu app only. INSTALLED 09:54Z: suite PASS inside build.sh (engine output
      43/43, swift 76, install.sh 3/3); install.sh "version 0.3.5 (was 0.3.4)"; the new menu app started
      10:54:28 local; agent (68048) and engine NOT restarted; prodmac46 stopped, connected, volume 35. (The
      engine's `-a 0:1` is Simon's own Settings change at 09:52:45Z, before the install.) VERIFIED LIVE by
      Simon the same day ("works"). The failed-save message itself was not seen (no save failed).
    - **0.3.6** (Simon: "build and install", 2026-10-12): the `CODE-REVIEW 2026-10-12 (2)` fixes. INSTALLED
      10:13Z: install.sh "version 0.3.6 (was 0.3.5)"; agent restarted (its cdhash changed), "agent started:
      LyrionPlay 0.3.6 (202610121112)", engine on the DragonFly with `-V`, "LMS: using Simons Music". NOT
      live-tested.
    - **0.3.7** (Simon: "build and install", "Yes, 0.3.7", 2026-10-12): the `CODE-REVIEW 2026-10-12 (3)`
      fixes (test messages, `recordRefusal`, `nearestOffered(on:)`); no change in behaviour. INSTALLED
      10:53Z with prodmac46 stopped: suite PASS inside build.sh (engine output 43/43, swift 76, install.sh
      3/3); install.sh "version 0.3.7 (was 0.3.6)". The agent restarted, as expected, since its cdhash
      changed: "agent started: LyrionPlay 0.3.7 (202610121153)", engine on the DragonFly with `-V`, "LMS:
      using Simons Music". LMS: connected, stopped, `digital_volume_control` 1, volume -35. That is
      muted, as before the install (the Mac mute at 10:46:10Z).
    - **0.3.8** (Simon: "rebuild and install", 2026-10-12): the `DOCS PASS 2026-10-12` (NOTICES.txt's
      dsd2pcm line, build.sh's header, the pages). INSTALLED 11:08Z: suite PASS inside build.sh (engine
      output 43/43, swift 76, install.sh 3/3); install.sh "version 0.3.8 (was 0.3.7)", "the player is
      unchanged: it keeps running" (agent 56294 and engine not restarted, by design); new menu app
      started 12:08:55 local; the installed NOTICES.txt has the dsd2pcm line.
    - **0.3.9 / 0.3.10** (Simon: "yes" to bundling the licence texts, 2026-10-12): `DOCS PASS 2026-10-12`'s
      licence texts; 0.3.10 adds the GPLv3 text that 0.3.9 lacked. INSTALLED 11:17Z: suite PASS inside
      build.sh each time; "the player is unchanged: it keeps running"; 15 files in `licences/`.
    - **0.3.11** (Simon: "update all accordingly we need this to be correct", 2026-10-12): `A RELEASE
      CARRIES ITS SOURCE`. Built with `--release` (suite PASS): `dist/LyrionPlay-0.3.11.zip` (1.3 MB, 15
      licence texts in the app) and `-codec-sources.zip` (15 MB, 9 archives, each SHA-256 matching
      build-deps.sh); the installed NOTICES.txt names v0.3.11. INSTALLED 11:26Z from that build. The
      player RESTARTED: the copyright lines moved output_coreaudio.c's `__LINE__`s, so the engine's
      cdhash changed (no behaviour change); "LMS: using Simons Music" after.
    - **0.3.12** (Simon: "build and install", after 0.3.12 was named, 2026-10-12): the `CODE-REVIEW
      2026-10-12 (4)` fixes (the DSD rate in full in the menu; the release step checking the codec
      archives' SHA-256; the licence helper; a comment). prodmac46 checked first: stopped, volume 35.
      INSTALLED 13:42Z: suite PASS inside build.sh (engine output 43/43, swift 76 in 17 suites, install.sh
      3/3); install.sh "version 0.3.12 (was 0.3.11)", "stopped the old player" (PlayerCore is in the agent,
      so its cdhash changed); agent.log "agent started: LyrionPlay 0.3.12 (202610121442)", engine on the
      DragonFly with `-V`, "LMS: using Simons Music"; LMS: connected, stopped, volume 35,
      `digital_volume_control` 1, queue 10 tracks as before; NOTICES.txt names 0.3.12; `licences/` the same
      15 texts. NOT live-tested: the new DSD label needs a DoP play (the FiiO; the DragonFly tops at 96k).
    - **0.3.13** (Simon: "build and update", "Yes, 0.3.13", 2026-10-12): the `CODE-REVIEW 2026-10-12 (5)` fixes
      (build.sh stops on a failed codec build or make-icon compile, the release's codec check first and the
      app zip last, the report and flush tests, the agent's log line); the engine source unchanged.
      prodmac46 checked first: stopped, volume 35. INSTALLED 14:34Z: suite PASS inside build.sh (engine output
      45/45, swift 76 in 17 suites, install.sh 3/3); install.sh "version 0.3.13 (was 0.3.12)", "stopped the
      old player" (the agent's cdhash changed); agent.log "agent started: LyrionPlay 0.3.13 (202610121533)",
      engine on the DragonFly with `-V`, "LMS: using Simons Music" 2 s later; LMS: connected, stopped, volume
      35, `digital_volume_control` 1, queue 10 tracks as before; menu app running; NOTICES.txt names 0.3.13;
      `licences/` 15 texts. The first build.sh run with the codec step's new log (`build/build-deps.log`).
    - **0.3.14** (Simon: "build and update all docs", "Yes, 0.3.14", 2026-10-12): the `CODE-REVIEW
      2026-10-12 (6)` fixes (a good Save keeps a switch-on error; the release stepper reads "never" at 0 and
      the Exclusive caption says so; build.sh's comment) and the docs: INSTALL.md's release time at 0
      ("reads *never*", the DAC kept while the player is on), and the two release zips in README.md's build
      block and INSTALL.md's Building section (round (5) fixed only the Layout line); pages regenerated by
      `bump-version.sh` (index.html has neither, unchanged). prodmac46 checked first: stopped, volume 35.
      INSTALLED 15:15Z: suite PASS inside build.sh (engine output 45/45, swift 76 in 17 suites, install.sh
      3/3); install.sh "version 0.3.14 (was 0.3.13)", "the player is unchanged: it keeps running" (only the
      menu app changed: agent 19517 and engine 19520 from 0.3.13 still running, by design); new menu app
      started 16:15:40 local; both new strings in the installed binary; NOTICES.txt names v0.3.14;
      `licences/` 15 texts; LMS after: connected, stopped, volume 35, `digital_volume_control` 1, queue 10
      tracks. Fix 2 VERIFIED LIVE by Simon 2026-10-12 ("yes I see never now": the stepper at 0; then
      "correct I see it": the Exclusive caption at 0, read with the stepper at 0 unsaved). Fix 1 STAGED + VERIFIED LIVE 2026-10-12 (Simon: "you can stage it"): a `ditto` copy of the installed
      0.3.14 at `<scratchpad>/AppTranslocation/LyrionPlay.app` (no quarantine: the check is the path string,
      so Gatekeeper's real translocation was not needed); Simon switched the installed player Off and
      quit its menu (one menu at a time, `MenuPresence.claim`), the copy was opened, Player On gave the
      install.sh message, then Settings > Save and Close (settings.json rewritten 16:24:46 by the copy,
      values identical to the backup) and the message STAYED (Simon: "yes"). A first try proved
      nothing: no save had happened (the file's mtime predated the copy), so check the mtime. Restored:
      copy quit, installed menu reopened, Player On by Simon: the launch agent plist identical to its backup;
      agent 75372 "agent started: LyrionPlay 0.3.14 (202610121614)" (the first 0.3.14 agent), engine on the
      DragonFly, "LMS: using Simons Music"; LMS: connected, stopped, volume 35, `digital_volume_control` 1,
      queue 10 tracks. Copy and backups deleted.
    - **0.4.0** (Simon: "installl it", "0.4.0" to version up, "Keep the old ID", 2026-10-12): `ONE PLAYER
      PER DAC`, `FIXED HOLDS THE LMS VOLUME`, device players named "<Mac's name> <device's name>", and `THE
      OLD PLAYER CARRIES ON`. prodmac46 checked first: PAUSED, volume 22, 10 tracks (the restart stops a
      paused player, as before). `bump-version.sh minor`; `build.sh --install`, suite PASS inside it (engine
      output 52/52, swift 90 in 21 suites, install.sh 3/3; the one Swift warning the known
      `SendableClosureCaptures`). INSTALLED 19:57Z: install.sh "version 0.4.0 (was 0.3.14)", "stopped the old
      player". agent.log: "agent started: LyrionPlay 0.4.0 (202610122056)", "settings from an older version
      moved to settings-0.3.json; starting with the defaults", "prodmac46 carries on as the earlier
      version's player 96:57:54:14:bd:87", engine of prodmac46 on the DragonFly (the macOS output) with
      `-N …/players/follow/name -f …/engine-follow.log -a 0:0 -C 30 -V`, "LMS: using Simons Music". LMS:
      ONE SqueezeLiteMac player, prodmac46 `96:57:54:14:bd:87`, connected, stopped, volume 22,
      `digital_volume_control` 1, queue 10 tracks. One engine running. `players/follow/` holds mac, name
      ("prodmac46"), engine.pid. NOT live-tested: everything in §C's live list.
    - **0.4.1** (Simon: "build and install", "0.4.1" to version up, 2026-10-14): `A STUCK DB PROPERTY
      FIXED` (the engine's `read_device_db`), INSTALL.md's two volume lines. Both players checked first:
      stopped (prodmac46 51, the DragonFly's player 13). `bump-version.sh patch`; `build.sh --install`,
      suite PASS inside it (engine output 55/55, swift 90 in 21 suites, install.sh 3/3). INSTALLED
      12:54Z: install.sh "version 0.4.1 (was 0.4.0)", "stopped the old player"; agent.log "agent started:
      LyrionPlay 0.4.1 (202610141354)", engines of the DragonFly's player and of prodmac46 (Follow, on
      the Melomania P100), "LMS: using Simons Music". LMS after: both connected, stopped, volumes 51 and
      13, `digital_volume_control` 1, queues 7 tracks, as before.
    - **0.4.2** (Simon: "build and install", "0.4.2" to version up, 2026-10-14): `THE DEVICE STAYS WHERE THE
      MAC PUT IT`, `A MAC MOVE UNMUTES LMS AT ITS LEVEL`, INSTALL.md's two volume lines. Checked first:
      prodmac46 the only LyrionPlay player connected, stopped, volume 48, 7 tracks (the DragonFly's player
      not connected). `bump-version.sh patch`; `build.sh --install`, suite PASS inside it (engine output
      69/69 with the matrix, swift 92 in 21 suites, install.sh 3/3; build warnings the same 7 lines as
      0.4.1's). INSTALLED 20:23Z: install.sh "version 0.4.2 (was 0.4.1)", "stopped the old player";
      agent.log "agent started: LyrionPlay 0.4.2 (202610142122)", engine of prodmac46 on the MacBook Pro
      Speakers (`-V`, `-C 10`), "LMS: using Simons Music". LMS after: connected, stopped, volume 48,
      `digital_volume_control` 1, 7 tracks. Speakers read after (read-only `halread`): -25.89 dB, mute off:
      LMS 48's own level (gain 3328), not the -25.64 dB the Mac last reported (20:11:27Z, on 0.4.1). Most
      likely 0.4.1 put LMS's answer on right after that report (the defect fixed here), and 0.4.2's start
      took the device as it was (its level gives 48); this read cannot tell the two apart. NOT live-tested.
    - **0.4.3** (Simon: "buld and install", "0.4.3" to version up, 2026-10-14): `INLINE REVIEW 2026-10-14`
      (Follow's saved volume, `Settings.forSaving`; the shorter Fixed warning), `SOFTWARE ONLY WITHOUT A
      VOLUME CONTROL`, `FIXED, NOT FIXED AT 100%`, and the docs to match (README.md, INSTALL.md, pages).
      Checked first: prodmac46 and the DragonFly's player connected, both PAUSED (the agent restart
      stops a paused player; said beforehand). `bump-version.sh patch`; `build.sh --install`, suite PASS
      inside it (engine output 69/69, swift 93 in 21 suites, install.sh 3/3). INSTALLED 21:33Z:
      install.sh "version 0.4.3 (was 0.4.2)", "stopped the old player"; agent.log "agent started:
      LyrionPlay 0.4.3 (202610142232)", the DragonFly's engine `-a 0:1 … -V` (saved Device's own volume,
      Simon set it back at 21:04Z), prodmac46 on the MacBook Pro Speakers `-a 0:0 … -V`, "LMS: using Simons
      Music". LMS after: both connected, stopped (volume 37 and 13). The picker label, the one-choice
      lists and Follow's Save NOT yet seen live.
    - **0.4.4** (Simon: "build and install,", "0.4.4" to version up, 2026-10-14): `FIXED ON FOLLOW, NO-CONTROL
      DACS ONLY`, `DOP PLAYS AT FULL LEVEL` (the DoP caption), INSTALL.md to match. Checked first: prodmac46
      connected, PAUSED (said beforehand: the restart stops it); the DragonFly's player switched off.
      `bump-version.sh patch`; `build.sh --install`, suite PASS inside it. INSTALLED 22:18Z: install.sh
      "version 0.4.4 (was 0.4.3)"; agent.log "agent started: LyrionPlay 0.4.4 (202610142317)", prodmac46 on
      the FiiO M11 Plus `-a 0:0 … -D` (Follow saved Software, DoP on), "LMS: using Simons Music"; LMS after:
      connected, stopped, volume 47. VERIFIED LIVE by Simon the same day: "That all works and DoP works on
      follow without Exclusive mode."
    - **0.4.5** (Simon: "build and install", "0.4.5" to version up, 2026-10-14): the captions of `THE MAC'S
      VOLUME AND EXCLUSIVE MODE` (menu app only). Checked first: prodmac46 connected, PAUSED. `build.sh
      --install`, suite PASS inside it; install.sh "the player is unchanged: it keeps running", "version 0.4.5
      (was 0.4.4)"; menu app restarted 22:33:55Z; prodmac46 still paused and connected after. The captions NOT
      yet seen live.
- **APPLE SILICON ONLY — Simon, 2026-10-09.** arm64 only, macOS 14+. No universal builds.
- **NO VIRTUAL AUDIO DRIVERS — Simon, 2026-10-09.**
  - Simon: "we dont need blackhole it messes up things last time i installed it and was hard to
    remove all traces we wil use a dac when you need it".
  - Bit-exactness is proven by the engine's own output tap compared with an independent
    reference decode (`tools/bitcheck`), plus the DAC's DoP lock for the last hop.
- **TOOLS ARE BUILT HERE — Simon, 2026-10-09.**
  - He asked for an Apple-Silicon alternative to the universal CMake.app.
  - CMake 4.4.4 is built from source with the Command Line Tools (`deps/build-cmake.sh`,
    SHA-256 pinned). It lands in `deps/tools`, nothing system-wide.
  - No Homebrew: its `/opt/homebrew` dylibs must never reach the engine's link. `otool -L`
    must list system frameworks only.
- **THE 384K CAP — by design, 2026-10-09.**
  - The engine reports `MaxSampleRate` = min(device max, 384000) via `-Z`.
  - Why: LMS's pcm rate-code table (`SqueezePlay.pm` `pcm_sample_rates`, LMS 9.1) stops at
    384000 (`'>'`), and an unknown rate returns `'3'` = 44.1 kHz. A 705.6k/768k WAV streamed
    as pcm would therefore play at the wrong speed.
  - FLAC carries its rate in-band, so the cap only costs LMS a downsample of >384k files.
- **DOP IS A SWITCH — by design, 2026-10-09.**
  - Per device, keyed by UID, off by default. CoreAudio exposes no DoP capability; a DoP DAC
    just sees 24-bit PCM.
  - With the switch off, squeezelite converts DSD to PCM and resamples (`dsd.c:811`), so DSD
    still plays everywhere.
- **NO HTTPS IN THE ENGINE — by design, 2026-10-09.**
  - `CanHTTPS` is not advertised and no OpenSSL is bundled. LMS then proxies HTTPS streams
    (Qobuz, TIDAL) itself.
  - Smaller attack surface for the network-facing C code, and one fewer library to build and sign.
  - Re-raise only with a stream that LMS cannot proxy.
- **FIXED VOLUME LEAVES THE DEVICE ALONE — by design, 2026-10-09.**
  - With `-V` (device volume) and LMS "Output level fixed at 100%" (`audg adjust = 0`,
    `output.volume_fixed`), `set_volume` keeps digital gain at unity and does NOT touch the
    device's level.
  - `output_alsa.c`'s `-V` instead sets its mixer to 0 dB in that case (`set_volume(FIXED_ONE)` →
    `set_mixer(.., 0dB)`). On a headphone DAC whose volume control is the only one, that is full
    volume.
  - Fixed means "the player does no volume", so the listener's level stays where it was.
  - Since 2026-10-11 the app can set LMS's fixed mode itself, per device: `FIXED AT 100% PER DAC`.
  - Superseded for the app's *Fixed* (2026-10-12, `FIXED HOLDS THE LMS VOLUME`): Fixed now runs with
    `-a <f>:<e>:1[:<dB>]`, where the engine ignores LMS's level itself and holds a level on a DAC
    whose volume the Mac sets. This entry still describes `-V` with LMS's fixed flag set from
    outside (Material), before the agent puts it back.
- **FIXED HOLDS THE LMS VOLUME — DECIDED by Simon 2026-10-12, BUILT in tree the same day, NOT installed**
  (§C `PLAYERS AND FIXED BUILT 2026-10-12`) (Simon: "Hold the LMS
  volume. This needs to be done properly no fudges this needs to be stable and do exactly what is
  planned"). On a DAC whose volume the Mac sets (the DragonFly, no knob), switching to Fixed puts the
  DAC's own volume at the level of LMS's SAVED volume for the player at that moment (17 -> -48.8 dB,
  the same curve as *Device's own volume*), unmuted, and keeps it there, whether the player was
  playing or paused (`FIXED SET UP WHILE PAUSED`) and after the DAC is plugged back in. Chosen over
  100% (what LMS's label and squeezelite do, §A3 `LMS FIXED IS A FLAG, NOT A LEVEL`): it is what
  Simon expects from "set the volume to the limit I want then chnage the settings to fixed", and what
  0.3.14 already does when the switch is made while playing. Known and accepted with it: Material
  shows the player fixed at 100 while the DAC sits at the held level; changing the held level means
  setting it again. A DAC with no volume control (the FiiO) is unchanged: its knob sets the level.
  **ONLY on a device with a detected volume control** (Simon, same day: "this is only for devices with
  volume control detected. In all other cases its 100% fixed just want to ensuire that dacw with no
  volume do not have software volume applied unless its on in the settings"). Every other Fixed is
  100%, with NO software volume. Today the engine meets that only through LMS's flag: a Fixed engine
  (no `-V`) puts the audg's gain on the samples whenever `adjust` is 1 (`process_audg`, slimproto.c:450;
  `set_volume`), i.e. any audg LMS sends while its setting still says "adjust": after an engine start
  before the agent sets fixed (~6 s in agent.log 17:41:32-38Z, if LMS sends one then), while the agent
  cannot reach LMS, or after a change in Material until the agent puts it back. The plan must make
  the engine itself ignore LMS's level in Fixed, whatever LMS sends.
  **As built:** the cog page reads `mixer volume ?` for that player when Fixed is chosen
  (`PlayerModel.chooseVolume`, `HeldVolume.from`: a muted player's negative volume gives its level; 0
  or no answer refuses) and shows it in the caption; Save refuses a Fixed with no level. The level is
  saved in `PlayerSettings.heldVolume`; the agent passes `-a 0:<e>:1:<dB>` (`LMSVolume.dB`, 17 =
  -48.84; since CODE-REVIEW 2026-10-14 (4), LMS's rounded gain, `HeldVolume.dB`: 17 = -48.83). The engine (`ca.fixed`) keeps the samples at `FIXED_ONE` from init and on every audg,
  ignores `-V`, and (`ca.hold`) puts the level on, unmuted, at init and at the first open of each
  device ID (`put_held_level`, `ca.hold_dev`), never moved by LMS. Fixed without a held level
  (`-a 0:<e>:1`) leaves the device alone. Replay gain, an LMS setting of its own, still applies.
  Do NOT report "Fixed differs from upstream's 0 dB" once built.
- **FIXED AT 100% PER DAC — BUILT 2026-10-11** (Simon: "is it possible to add a fixed volume mode
  that would feed back to LMS to set the player to 100% fixed … save that setting per dac"; then
  "LyrionPlay, per DAC" for who owns the pref). INSTALLED as 0.3.0 2026-10-11, the put-back as 0.3.1; the
  switch both ways VERIFIED LIVE 2026-10-12 on the DragonFly; the rest owed (§B).
  - **The setting:** a third "LMS volume" choice per device (keyed by UID, like the other two),
    `VolumeMode.fixed`, "Fixed at 100%". The engine gets no `-V`, so it never moves the device's
    level, even on an audg LMS sends before the pref is set; once LMS says fixed (audg adjust 0),
    the gain is unity (`slimproto.c:448`). The engine is UNCHANGED.
  - **LyrionPlay OWNS the pref, both ways (Simon's choice; the other option, "only undo what it
    set", was declined):** the agent's LMS check (every 5 s, and at once after a settings change; a change to or from the
    device's own volume restarts the engine and follows at the NEXT check, 6 s live: `CODE-REVIEW
    2026-10-12` finding 6) reads
    `digital_volume_control` from the `status` it already asks for, and when it differs from the
    engine device's mode sends `playerpref digitalVolumeControl 0` (Fixed) or `1` (device, software).
    So a switch from a fixed DAC lands right, and a change made in LMS or Material is put back at
    the next check. NOT A FINDING: that a hand-set LMS fixed setting is turned back on for a device
    not set to Fixed (decided; INSTALL.md says so).
  - **Refusal guard:** after a send the agent reads the pref back (`digitalVolumeControl(player:)`);
    if LMS did not keep it (its validator refuses 0 without `HasDigitalOut`; the engine always sends
    `HasDigitalOut=1`, so NO WRITER today), it logs once and does not send again until the device
    or its mode changes. The read-back, not the next check, decides, so a change made in Material
    within 5 s of a send is put back, not taken for a refusal. A missing read-back is not a refusal.
  - **agent.log:** "LMS volume for <device>: setting it to fixed at 100% / turning volume control
    back on, as this device's setting says"; the refusal line.
  - **Settings window:** the caption under the picker says what the choice does, and never "fixed"
    outside Fixed (Simon, 2026-10-12: "If yuo have a DAC chosen, devices volume is not fixed you say it
    is", of 0.3.3's "LMS's own fixed-volume setting for this player follows this choice" under *Device's
    own volume*). Now: *Device's own volume* "The LMS volume slider sets X's own volume." (offered only
    with a volume control, `ONLY WHAT A DEVICE OFFERS`);
    *Software* "The LMS volume slider scales the samples; X's own volume stays where it is."; each with the
    keys note on a device with a volume control. With Fixed, that LMS sends full level, and "turn it down before saving" when the SAVED mode scales
    the samples (`VolumeMode.scalesSamples`: software only; the device's own volume saved on a device
    with no Mac volume control is read as software by `Settings.options(for:)`), since from software volume Fixed is louder at once (Software and
    Fixed start the same engine, so nothing restarts). Until `CODE-REVIEW 2026-10-12` finding 2 it
    keyed on the device having no volume control, so Software on the speakers or the DragonFly got
    no warning. No volume-keys part under Fixed; the other two choices say where the keys work (§B,
    `THE VOLUME KEYS ON A FIXED DAC`, Simon's wording 2026-10-12).
  - **Volume put back (FIXED 2026-10-11, Simon: "okay apply the fix"):** LMS's hook for this pref
    saves a faded (temporary) volume as the real one (`THE DVC HOOK SAVES A FADED VOLUME`), which
    left the rig at volume 0. The agent reads the saved volume (`mixer volume ?`) before the send and
    after it, and when it changed sends `mixer volume <before>` (`volumeRestore`), which also moves
    Material's slider; a negative (muted) volume is never sent (`mixer volume -N` is RELATIVE), and the
    hook does not change one anyway. agent.log: "LMS saved its faded volume (N) as the player's volume
    when the setting changed; put back: mixer volume M". A user's own slider move inside the ~60 ms
    between the two reads would be undone: accepted. Tests `aFadedVolumeLMSSavedIsPutBack`,
    `aMutedVolumeIsNeverPutBack`; mutants (a muted volume put back; put back when unchanged; a
    fractional volume rounded) each fail. Suite PASS, swift 72 in 17 suites. INSTALLED as 0.3.1,
    VERIFIED LIVE 2026-10-12 (§B).
  - **Not done:** the switch between devices is not instant: the pref follows at the next check
    (≤5 s plus the reconnect), so a track already playing at the switch plays at the old mode
    until then (during that window nothing moves the device's level).
  - **Tests:** `Arguments.fixedVolumeNeverTouchesTheDevice`, suite `FixedAtFullPerDAC` (7: once,
    both ways, put back, refusal not a loop, no read-back, status parse, settings file), settings
    round trip with `.fixed`. New API, so no anti-run on the old code; MUTANTS instead, each failing
    its test: `.fixed` passing `-V`; "only undo" (non-fixed modes send nothing); a refusal retried
    every check; a refusal never cleared; no read-back taken as a refusal; the status field read as
    a string only. `scripts/test.sh` PASS (swift 70 tests in 17 suites); agent and app build, the
    one warning the known `SendableClosureCaptures` in `refreshLMS` (the new task captures an
    `OSAllocatedUnfairLock`, not `self`).
- **ONLY WHAT A DEVICE OFFERS — Simon, 2026-10-12** ("we need to block device volume as an option if it
  doesnt offer it, block fixed on MacOS outputs"; then, asked: "Everything not a DAC", and a blocked
  choice already saved "Treat as allowed choice").
  - `VolumeMode.isOffered(by:)`: *Device's own volume* only with a volume control the Mac can set
    (`device.volume`); *Fixed* (labelled *Fixed at 100%* until 2026-10-14) only on a DAC
    (`DeviceCaps.isExternal`: usb, thunderbolt,
    firewire, pci, avb, the test that already sets exclusive mode's default), so never on built-in,
    Bluetooth, AirPlay or HDMI; *Software* everywhere (since 2026-10-14 only without a volume control:
    `SOFTWARE ONLY WITHOUT A VOLUME CONTROL`). The picker lists only those (`offered(by:)`); the
    old "Device volume (none here: software is used)" label is gone.
  - A saved choice the device does not offer is read as the nearest offered (`nearestOffered(on:)`, was `offered(on:)`) in
    `Settings.options(for:)`, which EVERY reader uses (engine arguments, the agent's LMS sync, the
    picker, the caption, the warning): device volume without a control -> software (what the engine
    already played it as: `-V` with no control is software gain, so no change heard); Fixed on a Mac
    output -> the device's own volume (software without a control), so the agent turns LMS's volume
    control back on. The Settings window's Save writes the corrected choice for the devices it lists.
  - On the rig nothing is read differently (DragonFly saved `device`, FiiO `software`, the speakers
    unsaved): the engine's arguments are unchanged.
  - Tests `eachDeviceOffersOnlyWhatItHas`, `aBlockedChoiceSavedIsReadAsOneOffered` (new API; MUTANTS:
    Fixed offered everywhere FAILS both, no correction in `options(for:)` FAILS the second);
    `fixedVolumeNeverTouchesTheDevice` and `fixedIsLouderOnlyAfterSoftwareVolume` moved from the speakers
    (Fixed blocked there now) to a DragonFly fixture (its real probe line); an HDMI fixture with no
    control. Suite PASS (swift 76).
  - **Live report on 0.3.4, 2026-10-12** (Simon: "I still see all options and can chnage them on all
    outputs", "this is not doing anything different to previous version"): NOT A BUG. The rule judges the
    DEVICE behind the choice, and both entries Simon looked at were the DragonFly ("Follow the macOS
    output" followed it, as the macOS output), a DAC with a volume control, which offers all three, as in
    0.3.3. Only the speakers (2 choices) and the FiiO (2; not connected then) differ. Simon, told so: "I
    see what the issue was and makes sense". PROPOSED, NOT BUILT, no decision: no Fixed under "Follow the
    macOS output" whatever it follows; hiding Exclusive/DoP on Mac outputs (the speakers' saved `dop` is
    true; what that does on the speakers was not checked).
- **A RELEASE CARRIES ITS SOURCE — 2026-10-12** (Simon: "so we are ok license wise to release this",
  then "update all accordingly we need this to be correct"). The engine is GPLv3 and links FAAD2 (GPL),
  mpg123 and soxr (LGPL 2.1) and the BSD/Apache codecs statically, so a binary given out must come with
  its Corresponding Source and the licence texts:
  - **In the app** (build.sh): `Contents/Resources/licences/`, 15 texts (`DOCS PASS 2026-10-12`), and
    `NOTICES.txt` with `<version>` replaced by the build's version, naming the tag and the sources zip.
  - **`build.sh --release`** makes `dist/LyrionPlay-<v>.zip` AND `dist/LyrionPlay-<v>-codec-sources.zip`:
    the 9 archives `deps/build-deps.sh` fetches (read from its `fetch` lines; it stops if that is not 9,
    one is missing, or one differs from the SHA-256 build-deps.sh pins, since `CODE-REVIEW 2026-10-12 (4)`), build-deps.sh itself, and a README naming the tag.
    Since `CODE-REVIEW 2026-10-12 (5)` that check runs straight after the codec build, before anything
    else is built, and again on the copies; the sources zip is made first and the app's zip last, so a
    release that stops leaves no app zip without its sources.
  - **What a release needs, beyond the build:** the `v<version>` tag is ALREADY part of every release
    (Simon, 2026-10-12: "we always add a version tag to our release build part of the release process";
    do not raise it as a risk). The one new step: attach BOTH zips, the app's and
    `-codec-sources.zip`, to that release page. NOTICES, INSTALL and README point users there.
  - **Copyright:** the files written for LyrionPlay say "(c) 2026 CrystalGipsy" (output_coreaudio.c
    beside squeezelite's authors, output_coreaudio_conv.h, Makefile.coreaudio, both test files), as
    LICENSE does. `engine/UPSTREAM.md` opens with the section 5(a) modification notice and date.
  - **Not licence, Simon's call:** "Lyrion" in the name and the Lyrion waveform in the icon are a
    trademark courtesy; the docs say it is not affiliated. Asking the Lyrion maintainers before an
    announcement was suggested, not done.
  - The menu app and agent (MIT) run the engine as a separate program (arguments in, lines out on
    stdout): a separate work, not GPL-bound.
- **THE FORMAT CHANGES WHEN OUTPUT HITS THE DAC — Simon, 2026-10-12** ("1 and 2 are not issues this
  is how dacs work the change will happen when output hits the dac not before"). /code-review 2026-10-12
  (2) reported that after the idle release, the next open says the LAST track's format at once
  (`ca_report_format`, `ca.track_rate`/`ca.track_fmt`, e.g. "176400 dop" while a 176.4k PCM track
  buffers), and that the test `the_idle_release_is_reported` replays the same DSD64 so cannot see it.
  DECLINED: the report follows the IOProc's record of what reached the DAC, and a new track's format
  reaches it only at that track's start. Do not report the window between an open and the track start,
  and do not propose reporting the pending track first.
  - **The lag is not a finding either — Simon, 2026-10-12** (/code-review 2026-10-12 (6) finding 4,
    DISMISSED: "I dont care about the lag"). The comment above `ca_report_format` (and the engine note
    under §C's DSD rate entry) says "every ~100 ms"; in fact slimproto runs it on a wake or on
    `wait_readwake(ehandles, 1000)`'s timeout. A rate change wakes it at once (`ca_reopen` ->
    `wake_controller()` in the IOProc), but a gapless start at the SAME device rate (DSD64 DoP <->
    176.4k PCM, DSD128 <-> 352.8k) does not, so the line and the menu can trail the DAC by up to ~1 s.
    Do not report the lag, the cadence or the "~100 ms" wording, and do not propose a wake at the
    track start.
- **SAVE AND CLOSE — Simon, 2026-10-12** ("can we add a save and close option as well as save"). The
  Settings window has Revert, Save (still the Return key) and Save and Close, which saves and then closes
  the window (`dismissWindow(id: "settings")`) ONLY when the save worked (`PlayerModel.save` now returns
  whether it did; its two callers are these buttons), so a failed save keeps the edits on screen. A failed
  save's message now shows in the Settings window too, in red above the buttons (Simon: "yes show it in
  window"): `PlayerModel.saveError`, set by a failed save, cleared by a good one, by Revert and when the window
  opens (`clearSaveError`, which also clears `lastError` when it holds the same message);
  `lastError` still carries it to the menu panel as before (`lastError` also holds switch-on errors, which
  do not belong in Settings). INSTALLED as 0.3.5, VERIFIED LIVE by Simon 2026-10-12 ("works"); the
  failed-save message not seen (not staged: it would mean making Simon's settings file unwritable).
  A failed save followed by a good one loses a switch-on error (the failed save overwrites `lastError`,
  then the good save's `clearSaveError` clears the matching message): **DISMISSED by Simon 2026-10-12**,
  `CODE-REVIEW 2026-10-12 (7)` finding 3 ("too theoritcal if it shows up in use will fix"). It needs an
  unwritable settings file, never seen. Re-raise only if it shows up in use.
- **SOFTWARE AFTER A PAUSED -V DAC — KNOWN LIMITATION, NOT FIXING, Simon 2026-10-12** ("just leave
  software its a known limitation I am not fixing it and should be marked as this"; `CODE-REVIEW
  2026-10-12 (7)`). A switch from *Device's own volume* to *Software* made while LMS is paused leaves a
  DAC with a volume control (the DragonFly) muted at its minimum, where LMS's pause fade put it
  (`apply_volume` mutes at gain 0). Software never touches the device's own volume, so it plays into
  that until the device's volume is raised (Audio MIDI Setup, or a switch back). Do not report it, and
  do not propose setting the DAC's volume for Software. **Unreachable since 2026-10-14**: Software is no
  longer offered on a device with a volume control (`SOFTWARE ONLY WITHOUT A VOLUME CONTROL`).
- **SOFTWARE ONLY WITHOUT A VOLUME CONTROL — DECIDED by Simon 2026-10-14, INSTALLED as 0.4.3, not
  live-tested** ("can we remove software then please as that is pointless on volume control dacs its
  purely to add control when there is nothing at all"). `VolumeMode.isOffered(by:)`: *Software* only on
  a device with no volume control the Mac can set, so every device offers exactly one of *Device's own
  volume* and *Software*, plus *Fixed* on a DAC: the DragonFly device/fixed, the FiiO
  software/fixed, the speakers device, HDMI software; *Follow the macOS output* one choice wherever it is.
  So Follow's mode changes with the output it follows (the DragonFly or the speakers: its own volume; the
  FiiO: Software, or Fixed since `FIXED ON FOLLOW, NO-CONTROL DACS ONLY`): checked by Simon 2026-10-14 ("it does but switches between dacs"), as intended, not a finding.
  - Software already saved on a device with a control is read as its own volume by the existing
    `nearestOffered(on:)` (no migration): `-V`, LyrionPlay turns LMS's volume control on (it was on for
    Software too), no "louder" warning. Simon's DragonFly, saved Software by the caption check of
    `INLINE REVIEW 2026-10-14`, reads as its own volume. A Follow record saved Software by that round's
    finding 1 is read as its own volume on any output with a control.
  - First asked (same day): remove Fixed AND Software where the device has a control, Fixed to be set
    by hand in LMS. Put to Simon: the agent puts LMS's fixed setting back in the other modes (`FIXED AT
    100% PER DAC`); set while paused, LMS's fixed leaves a `-V` DAC muted at its minimum (`FIXED VOLUME
    LEAVES THE DEVICE ALONE`, `FIXED SET UP WHILE PAUSED`) and LMS saves its faded volume (`THE DVC HOOK
    SAVES A FADED VOLUME`). Simon then chose Software only: Fixed and its hold stay as built.
  - Tests: `eachDeviceOffersOnlyWhatItHas` (new table + one-of-the-two rule),
    `aBlockedChoiceSavedIsReadAsOneOffered` (Software saved on the DragonFly and on Follow at the
    speakers read as own volume with `-V`), `fixedIsLouderOnlyAfterSoftwareVolume`, the Software control
    in the Fixed arguments test moved to the FiiO. MUTANT: the old rule (Software everywhere) FAILS 10
    expectations in 3 tests. Suite PASS; `swift build` of every target, the one known warning. INSTALL.md
    says when each choice is offered; the Software caption's keys note (dead now) removed.
  - Saved settings need no carrying over (Simon: "no migration needed fresh settings is all that is
    required this isnt out in the field"): never raise an old saved choice as a finding. `nearestOffered`
    stays because *Follow the macOS output* needs it at every output it moves to.
- **FIXED, NOT FIXED AT 100% — DECIDED by Simon 2026-10-14, INSTALLED as 0.4.3** ("lets
  drop 100% as its not with a volume control dac as yo have to manualy set it full volume as fixed sets
  no change from LMS not what the level is"). The LMS volume picker says *Fixed* (was *Fixed at 100%*),
  and every doc with it (Simon: "enure all docs reference it as fixed"): INSTALL.md, README.md (before
  the merge to main, as asked; its Software clause corrected in the same line), the regenerated pages: on a DAC with a volume control Fixed holds the level LMS had (`FIXED HOLDS THE
  LMS VOLUME`), so "100%" was wrong there. LMS's own setting keeps its name, "Output level is fixed at
  100%" (INSTALL.md, the agent's log line and comments quote it). Never put "at 100%" back on the choice.
- **FIXED ON FOLLOW, NO-CONTROL DACS ONLY — DECIDED by Simon 2026-10-14, INSTALLED as 0.4.4, VERIFIED LIVE by
  Simon the same day** ("That all works")
  ("with not having fixed in Follow MacOS we cant set the FiiO as fixed"; then "yes" to the rule). Reverses
  2026-10-12's no Fixed for *Follow the macOS output* ("MacOS 2 options") for a DAC with no volume control
  only: `VolumeMode.isOffered` `.fixed` = `device.isExternal && (!follow || device.volume == nil)`. Follow on
  the FiiO: Software or Fixed; on the DragonFly, the speakers: its own volume only; HDMI: Software.
  - Why only there: such a DAC has nothing to hold, so Follow never holds a level (`FIXED HOLDS THE LMS
    VOLUME` stays a device player's), and Follow's saved Fixed reads as each other output's one choice
    (`nearestOffered`), so it is never carried to a DAC with a control or to the speakers.
  - Every carrier: the engine gets `-a <f>:<e>:1` on the FiiO (full level at once, not waiting for LMS's
    flag); `syncFixedVolume` sets LMS fixed for the FiiO and turns its volume control back on at the next
    check (~5 s) when the macOS output moves to an output with a control, meanwhile a `-V` engine leaves the
    device where the Mac has it (`FIXED VOLUME LEAVES THE DEVICE ALONE`), so no full-level blast; each
    flip while paused saves LMS's faded volume, put back by `volumeRestore` as for any agent change;
    `chooseVolume` reads no LMS level on a DAC without a control; Save's held-level check skips it.
  - Tests: `eachDeviceOffersOnlyWhatItHas` (Follow on the FiiO `[.software, .fixed]`, speakers, HDMI),
    `aBlockedChoiceSavedIsReadAsOneOffered` (Follow saved Fixed: the FiiO `-a 0:0:1`, no `-V`, LMS fixed;
    the DragonFly its own volume, `0:0`). MUTANTS: the old rule FAILS 4 expectations; Fixed on every DAC
    for Follow FAILS 3. Suite PASS; `swift build` of every target. INSTALL.md says where Follow offers it.
- **THE MAC'S VOLUME AND EXCLUSIVE MODE — AS INTENDED, Simon 2026-10-14, wording INSTALLED as 0.4.5,
  not seen live** (Simon: "When on follow MacOS when using a DAC and its set to exclusive it stops the mac volume
  from doing anything this is as intended?"; then "yes was just checking"). Taking the DAC exclusively makes
  macOS move its own sound output to another device (`HOG MOVES THE DEFAULT OUTPUT`), so the Mac's volume
  keys and menu bar slider move that device, the engine (watching the DAC) reports nothing, and LMS does not
  move; LMS's slider still sets the DAC (`A HOG DOES NOT HIDE THE VOLUME CONTROL`). Not a finding, and not
  fixable while the device is held. The keys note under *LMS volume* (`volumeCaption`'s `keys`), INSTALL.md
  (both places) and README.md now add "with Exclusive mode off". The caption under the *Exclusive mode* switch
  adds (Simon: "update the text it displays in the app as well fof this so its clear"): "Meanwhile macOS
  sends its own sound to another output, so the Mac's volume keys don't change <device>."
- **DOP PLAYS AT FULL LEVEL — said on screen at Simon's request 2026-10-14, INSTALLED as 0.4.4, VERIFIED
  LIVE by Simon** ("That all works") (Simon, on *Follow the macOS output* playing DSD to the FiiO: "you can still control the
  volume but it doesnt do anything at all"; then "yes" to the caption). NOT A BUG: upstream `output.c`
  sets the gain to FIXED_ONE for any output that is not PCM, because scaling DoP frames breaks the DSD
  stream, so *Software* (LMS's slider scales the samples) cannot change DSD sent as DoP; *Device's own
  volume* moves the DAC's own volume and still works, Fixed is full level anyway, DoP off converts DSD to
  PCM, which the slider does scale. On a Software player with DoP on, the caption under the DoP switch
  (`dopCaption`) and INSTALL.md add: "DSD sent as DoP always plays at full level: the LMS slider doesn't
  change it. Use the DAC's own volume." Never report the inert slider as a defect. Turning LMS's fixed
  setting on only while DSD plays was advised against, not built (`THE DVC HOOK SAVES A FADED VOLUME`).
- **THE BOUNDARY AND THE REOPEN FLAG — by design, 2026-10-09.** Two places where the CoreAudio
  path deliberately differs from `output_pa.c`:
  - **The boundary.** `pa_callback` keeps calling `_output_frames` after a track start that
    changed `output.current_sample_rate`, so up to one buffer of the new track plays at the old
    rate before the stream reopens. `ioproc` breaks as soon as the rate differs and pads with
    silence.
  - **The flag.** `slimproto.c` clears `output.ca_reopen` BEFORE `_ca_open()`. `_ca_open` runs
    device calls unlocked, and the new IOProc may raise the flag again meanwhile; clearing after
    the call, as the PortAudio block does, would lose that request.
  - Also in `ioproc`: one 0 from `_output_frames` (a boundary at the very start of a call) gets
    one retry, so a same-rate gapless boundary never pads a buffer with silence.
- **THE SPIKE IS THE REAL IDENTITY — by design, 2026-10-09.**
  - The Phase 0 agent spike uses the real bundle id `com.crystalgipsy.lyrionplay` and agent
    label `com.crystalgipsy.lyrionplay.agent`.
  - The Local Network approval Simon gives during the spike then carries to the real app, and no
    "Spike" entries are left behind in System Settings.
- **MODEL NAME IS SqueezeLiteMac — Simon, 2026-10-10** ("change the players model to be
  SqueezeLiteMac this will then use materials Apple icon for the player by default").
  - **NOT A FINDING: the model name is MEANT to differ from the app name.** Simon, 2026-10-10:
    "mode name is meant to be different to the app name this isnt a bug or an issue its as
    planned for the logo to work. Don't want it flagged in reviews as an issue as it isn't."
    `SqueezeLiteMac` where the app, bundle, executables and pages say `LyrionPlay` is not
    inconsistent branding and not a leftover. Do not report it, and do not propose a
    `LyrionPlay` model name or a new Material icon entry as a fix: the name exists to match
    Material's existing `SqueezeLiteMac` key.
  - The agent passes `-M SqueezeLiteMac` (`EngineArguments.modelName`); it was `LyrionPlay`, which
    Material has no icon for, so the player showed its generic speaker.
  - LMS's `model` stays `squeezelite` (BASE_CAP in `engine/slimproto.c`). Material's
    `mapPlayerIcon` looks up `player-icons.json` by model, then by modelname, and
    `squeezelite` → `SqueezeLiteMac` is `{"svg":"apple"}` (checked on the rig's Material,
    2026-10-10).
  - The rules checked before modelname can't match: firmware ends `-pCP` (ours is
    `2.0.0-1609`), and playerid begins `b8:27:eb:` or `dc:a6:32:` (our MAC always has the 0x02
    locally-administered bit set, and `b8` and `dc` have it clear). A per-player icon the user
    picks in Material still wins.
  - Trade-off accepted: LMS shows "SqueezeLiteMac" as the player's model name, not "LyrionPlay".
  - Test `modelNameGivesMaterialsAppleIcon` (it failed with `LyrionPlay` in place).
  - INSTALLED in 0.2.2 (2026-10-10 10:42); LMS reports modelname `SqueezeLiteMac`. VERIFIED by
    Simon in Material the same day: "Logo works".

- **SILENCE FORMAT IS NOT A FINDING — Simon, 2026-10-11** ("Ive tested myself swithcing to pretty much most
  formats no silence its not needed so why we doing this? switch fine. Why are we messing with this
  silence when stopped or paused?"; then "Yes" to keeping the engine as 0.2.10).
  - **Do not report** which format the silence takes (DoP silence or PCM zeros) when stopped, paused,
    buffering, waiting for a synced start, around an open, at a rate change or at the idle release
    (`_silence_fmt`, `ca.track_rate`/`ca.track_fmt`, `silencebuf_dsd`, the OFF branch, `_ca_open`), nor
    claims that the DAC "flips to PCM", "clicks" or "loses its DSD lock" there.
  - **Why:** every such finding rests on squeezelite's "DSD silence keeps the DAC locked", which was
    never tested on Simon's DAC. The only data: up to 0.2.9 every idle release after DSD ended in
    ~2.9 ms of PCM zeros and Simon heard nothing wrong; his own switching between most formats is
    fine. Rounds 2, 3 and 4 and the 0.2.10 change each refined the rule on paper and opened the next
    finding (Simon: "We are going round and round the same thing every review").
  - **Live evidence, Simon on the FiiO, 2026-10-11 (after the decision):** a DSD128 file (DoP 352.8k)
    paused, then DSD256 (352.8k PCM on the FiiO), then back to DSD128: every switch played as it
    should. That is finding 1's own same-rate pair (`CODE-REVIEW 2026-10-11 (4)`), so it is not a
    problem in use either. The library does hold DSD128 (the round's "none" was wrong). 176.4k is a
    DoP rate only: PCM is not sold at 176.4k, and Simon expects it to switch as the higher pair does.
  - **Still a bug:** DoP silence at a rate no DoP track plays at, which the DAC plays as PCM noise (a
    square wave at Nyquist, ~-27 dBFS; round 1's fix, `_silence_fmt`'s rate check, stays); and anything
    Simon hears on the DAC, reported live.
  - **The engine stays as 0.2.10,** including 0.2.10's DoP silence to the close, which rests on the
    same untested premise and is not reopened either. `MATRIX_SIG` diffs any change against it,
    frame by frame.
- **A STALLED SERVER IS NOT A FINDING — Simon, 2026-10-11** ("as we cant test a stale server note
  to skip this in reviews as it will be fixed if and when it ever comes up. We would need a way to
  debug this though").
  - **Do not report** any finding whose writer is LMS stalling or answering late: a check that
    outlasts the agent's 2 s tick or 5 s cadence, a reply landing after a server change, discovery
    or `LMSClient.call` timeouts (2 s / 4 s), the menu or the volume keys lagging behind a server
    change. Two rounds found such races (`CODE-REVIEW AFTER 0.2.2` 1, `CODE-REVIEW 2026-10-11` 6);
    both are fixed and pinned in `ServerChoosing`. LMS answers `players` in ~30 ms on the rig, and a
    stall can only be staged with a stand-in server, so further rounds cost a lot to prove a case no
    one has seen.
  - **Re-raise only with a stall seen live,** from the agent.log lines below, named by time.
  - **The way to see one (agent.log, added 2026-10-11, `refreshLMS`; rules in `LMSCheckLog` since
    `CODE-REVIEW 2026-10-11 (2)`, suite `ServerCheckLogging`):** never a line per check, only
    - `LMS check of <name> (<host>:<port>) took N s`: the FIRST check of a run in which the server
      took over 2 s (`LMSCheckLog.slowAnswer`, the agent's tick) to answer the players and status
      requests, timed in the check's task with `SuspendingClock` (since CODE-REVIEW 2026-10-11 (3);
      before, the whole check, discovery included, against 4 s: `THE 4 S LINE SAW ONLY TIMEOUTS`). A
      request no one answers times out at 4 s, so a server that has gone is "took 4.0 s" once, then
      "did not answer" (0.2.7 wrote a line every ~6 s for a typed host that does not answer);
    - `LMS checks of … back under 2 s (N s), after K slower, the slowest M s`: the run's end (a
      quick failure ends one too, so not "answering"); a run is one server's: a server setting
      change, or a check of another server or of none, ends it unsaid;
    - `LMS check of … dropped after N s: begun with server setting "X", now "Y"`: the whole line for
      such a check, slow or not, and no part of a run;
    - `LMS: using <name> (<host>:<port>)` / `LMS: no server found` / `LMS: <name> … did not answer`:
      each change of the server the agent uses, and the first check after the agent starts or the
      server setting changes, whatever it finds (0.2.7 wrote nothing when that was no server).
    The engine's own link to LMS is slimproto (`-s`), logged in engine.log as ever.
  - **INSTALLED as 0.2.7, 2026-10-11 13:46Z** (Simon: "yes" to version up and install; player stopped
    first; suite PASS in build.sh). agent.log: "agent started: LyrionPlay 0.2.7 (202610111446)", then
    "LMS: using Simons Music (192.168.1.234:9000)" 2 s later, and no further LMS line while checks
    ran normally. Player connected again ~10 s after the restart.
- **SETTINGS CARRY OVER FROM 0.4.0 ON — Simon, 2026-10-14** ("I dont care about migrating older ones
  to this new build", "if we are moving up version from now then we need to ensure that does keep
  settings"). A settings.json written by any 0.4.x loads in every later build. `PlayerSettings`
  requires only `name`; a key a later build adds MUST decode as optional with a default, at both
  levels (`Settings.init(from:)`, `PlayerSettings.init(from:)`). Only a file below version 2 (0.3.x)
  is set aside; a file that does not decode is `Settings.Stored.unreadable`, never moved or written
  over by the agent. A change of format that cannot be read that way needs version 3 and a migration
  from 2, never a reset. The set-aside cut-off is `firstPlayersVersion` (2), never `currentVersion`;
  `save` always writes `currentVersion` (CODE-REVIEW 2026-10-15). A missing or unreadable file never
  renames a player: the agent writes no name over a name file (`THE NAME FILE HAS TWO WRITERS`). The
  Settings window shows the defaults for an unreadable file and says so; its Save keeps the file as
  settings-unreadable.json first (`Settings.save`). Settings from before 0.4: not migrated (`ONE PLAYER PER DAC`); never report
  their set-aside as a defect.
- **THE NAME FILE HAS TWO WRITERS — DECIDED 2026-10-15** (my design, on Simon's instruction: "The
  saving settings issuesis becoming boring … Saving settins should not be so complicated"). `players/<slug>/name` (squeezelite
  `-N`) is the player's name. Two things write it, and nothing else may: the Settings window's Save,
  for a Name typed there (`PlayerIdentity.writeName`, before settings.json, for the names
  `Settings.renames(since:devices:)` gives against what the window opened on), and squeezelite, for a
  rename made in LMS. The agent only makes a missing one (`createNameFile`), and restarts a running
  engine at a settings change only when the renamed player's file already holds the new name
  (`renameReached`). Why: from 0.4.0 the AGENT applied settings.json's names to the file and had to
  guess which ones were typed: 0.4.5 compared old and new settings (lost a rename saved while off),
  the 2026-10-14 tree kept a `settings-name` record, the 2026-10-15 tree added a `saved` flag, and each
  guess missed a case (CODE-REVIEW 2026-10-14 #2, 2026-10-15 #1, 2026-10-15 (2) #1 and #2). Only the
  window knows what was typed. Never move name writing back into the agent, and never write a name
  from a default. Names are `PlayerSettings.fitName`d (one line, 63 bytes of whole characters, what
  squeezelite's `fgets` keeps); a blank one is refused at Save. Known and accepted: the Settings
  window shows settings.json's name, not a rename made in LMS since (as 0.4.5 did); a rename in LMS
  in the ~2 s between Save and the engine's restart is overwritten by Save's name.

### A3. DISPROVEN — beliefs the code suggests that measurement killed

Not defects and not decisions: beliefs the code plausibly suggests, killed by a measurement or the
LMS source. A review re-derives them from scratch every time. Re-raise one only by disproving the
evidence it cites.

| Belief | Verdict | The evidence |
|---|---|---|
| NO RATE LIST: a player can tell LMS which sample rates its DAC supports, and LMS will transcode around the gaps | **WRONG** (LMS 9.1 source, 2026-10-09) | `SqueezePlay.pm` `%CapabilitiesMap` reads only `MaxSampleRate`, plus bare codec tokens matching `^[a-z][a-z0-9]{1,4}$`. `CapabilitiesHelper::samplerateLimit` downsamples only when the track rate is ABOVE that maximum, and keeps the family (`maxRate % 12000 == 0 && srate % 11025 == 0` → `maxRate * 11025/12000`). A gap BELOW the maximum (say 88.2k on a 44.1/48/96/192 DAC) must be resampled in the player: squeezelite `-R` with the `E` flag, "resample only if native rate not supported". |
| DSD IS PASSTHROUGH AT ANY RATE: LMS limits DSD to rates the player can take | **WRONG** | `convert.conf:389-395`: `dsf dsf * *` and `dff dff * *` with `# IFD`. The `D` capability is satisfied by the passthrough itself, so a player that lists dsf/dff gets raw DSD at ANY rate. squeezelite handles it: DoP when `DSD rate/16` fits the device's top rate, else DSD→PCM (`dsd.c:811`). |
| THE PLAYER APPLIES REPLAY GAIN: LMS applies replay gain (or transcodes to apply it) | **WRONG** | The player applies it. `Squeezebox::stream_s` packs `canDoReplayGain` into `strm` as a 16.16 multiplier; squeezelite stores it as `output.next_replay_gain` (`slimproto.c:384`) and multiplies it into the gain (`output.c:54`). Fleet memory `lms-streaming-http` records that there is no gain stage in LMS's transcode path. |
| BIT-PERFECT IS ALREADY HANDLED: Bit-perfect needs special handling of the volume code | **WRONG** — squeezelite already does it | `_write_frames` skips `_apply_gain` when both gains are exactly `FIXED_ONE` (`output_pa.c:464`), and `_output_frames` forces `FIXED_ONE` for any non-PCM (DoP/DSD) output (`output.c:173`). LMS "fixed at 100%" sends `audg` with `adjust=0`, which squeezelite maps to `FIXED_ONE` (`slimproto.c:447`). |
| NO HOG MODE UPSTREAM: squeezelite on macOS already does exclusive mode and hardware volume | **WRONG** | The macOS build uses `output_pa.c` (PortAudio). Its only exclusive option is WASAPI on Windows (`-a <latency>:1`). `-V`/`-X` (hardware mixer) are inside `#if ALSA` in `main.c`. No `kAudioDevicePropertyHogMode` anywhere in the tree. |
| NO DOP PROPERTY IN COREAUDIO: macOS can tell us whether a DAC accepts DoP | **WRONG** | CoreAudio has no DoP or DSD format or property. A DoP DAC presents ordinary LPCM formats (`kAudioStreamPropertyAvailablePhysicalFormats`). The DAC itself decides from the DoP marker bytes. |
| SMAPPSERVICE PINS THE FIRST BUILD: an agent registered with `SMAppService.agent(plistName:)` keeps working after a rebuild if the app is signed with the same self-signed identity | **WRONG** (measured on macOS 26.7.1, 2026-10-09) | The first build launched ("Successfully spawned ... because speculative"). After a rebuild, every launch died: kernel `AMFI: Launch Constraint Violation (enforcing) ... (Constraint not matched)`, launchd `OS_REASON_CODESIGNING`, job `properties = ... needs LWCR update \| has LWCR`. amfid: "signed by an unknown certificate chain", i.e. no Team ID, so the launch constraint can only pin the build's code hash. NOT cleared by `unregister()` + `register()`, by `lsregister -f` on the rebuilt bundle, or by bumping `CFBundleVersion` (launchd showed `parent bundle version = 2`, still refused). A classic `~/Library/LaunchAgents` plist loaded with `launchctl bootstrap` has no such constraint, and ran rebuilt code fine. Re-raise only with a Team ID (Developer ID or Apple Development certificate). |
| ARGV0 IS BUNDLE-RELATIVE: an agent can find its sibling executables from `CommandLine.arguments[0]` | **WRONG under SMAppService** (2026-10-09) | With `BundleProgram`, `argv[0]` was `/Contents/MacOS/spike-agent`, so `Process` looked for `/Contents/MacOS/spike-net` and got "doesn't exist". A classic agent's `argv[0]` is the full `Program` path, but `Bundle.main.bundleURL` is right in both cases; always use it. |
| EACH EXECUTABLE ASKS ONCE: the agent's Local Network approval covers the programs it starts | **WRONG** (2026-10-09) | With the agent approved (its URLSession reached `plex:9000`), its child, a separately signed executable using BSD sockets, got `connect ... No route to host (errno 65)` and no discovery reply, until a second prompt was approved. Then: PASS. Expect one prompt for the agent and one for `squeezelite` on first use. |
| APPROVAL SURVIVES A REBUILD: Local Network approval is lost on every rebuild | **WRONG with a stable identity** (2026-10-09) | The child was rebuilt with a new code hash (`a7a4fe76...` → `be6c836a...`, build-stamped), and its FIRST run passed TCP, discovery and HTTP with no new prompt. Its designated requirement is `identifier ... and certificate leaf = H"bb27c270..."`, which a rebuild does not change. |
| FB16131937 NOT REPRODUCED: BSD sockets are blocked under launchd regardless (Apple FB16131937) | **NOT REPRODUCED** on macOS 26.7.1 (2026-10-09) | Once approved, plain BSD-socket TCP and UDP broadcast from a launchd agent's child succeeded on every run. The failure that looked like that bug (EHOSTUNREACH) was only the approval still pending. |
| DSD256 IS PCM ON THE FIIO: the FiiO M11 Plus plays DSD256 natively, so the player should send it as DSD | **WRONG on a Mac** (measured 2026-10-09) | DoP carries DSD at rate/16 in 24-bit PCM words, so DSD256 needs a 705.6 kHz PCM link. The FiiO's macOS driver offers at most 384 kHz (`kAudioDevicePropertyAvailableNominalSampleRates`), so its DoP ceiling is DSD128. macOS has no native-DSD path (no ASIO; CoreAudio has no DSD format). squeezelite therefore converts DSD256/512 to PCM and resamples to 352.8 kHz (`dsd.c:811`, `resample_newstream`). Simon saw "PCM" on the FiiO for both, and DSD for DSD64. A DSD-to-DSD128 remodulator (as HQPlayer has) is the only way to keep it DSD, and squeezelite has none. |
| A CRASHED AGENT ORPHANS ITS ENGINE: launchd takes the engine down with the agent when the agent dies | **WRONG** (measured 2026-10-09) | `kill -9` of the agent left its engine running with parent PID 1, and the restarted agent started a second engine with the same player identity. Foundation's `Process` starts children in their own process group, which launchd's process-group kill on job exit does not cover. Fix: the agent writes `engine.pid`; at start, `stopOrphanedEngine` stops that PID only if it is alive AND `proc_pidpath` equals our engine binary. Re-measured: "stopping engine 84464, left running by a previous agent", then exactly one engine. Never match engines by name. |
| NO SWIFTUI MACROS WITHOUT XCODE: SwiftUI builds fine with the Command Line Tools | **PARTLY WRONG** (2026-10-09) | `@State` failed: "plugin for module 'SwiftUIMacros' not found". The CLT plugin folder (`/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins`) holds only `libObservationMacros`, `libSwiftMacros` and `testing`. `@Observable` and `@Bindable` work; `@State` (a macro in the macOS 26 SDK) does not. The app keeps all state in an `@Observable` `PlayerModel.shared`. Installing Xcode would lift this; it is not needed. |
| A SHORTCUT QUIT THE MENU: playback made the menu bar icon disappear | **WRONG** (measured 2026-10-09) | Simon: the icon went "when I started to play". The unified log shows the menu app's panel opened at 22:47:20 over VS Code and kept the keyboard (WindowServer "outbound to keyThief") while VS Code was in front. At 22:48:51 a modifier plus a key reached it, AppKit ran `performKeyEquivalent:`, and launchservicesd logged `QUITTING` 50 ms later: an orderly quit, with no crash report. The first track started 16 s after that, at 22:49:07. The agent and engine never stopped. Only ⌘Q terminates a default SwiftUI app, so the key was almost certainly ⌘Q, though the log does not name it. Fix: `CommandGroup(replacing: .appTermination) {}` removes ⌘Q, and `applicationShouldTerminateAfterLastWindowClosed` returns false. Any quit not from Quit Menu is logged with its event to `~/Library/Logs/LyrionPlay/menu.log` and is never refused, since logout needs it. The ⌘Q removal is UNVERIFIED by keypress (no Accessibility access to send one). |
| READ-BACK IS NOT THE LEVEL SET: a device reports the dB the engine just set, so comparing with the requested level tells the user's changes from ours | **WRONG** (measured 2026-10-10) | The MacBook Pro speakers move in coarse steps. With the record set to the REQUESTED dB, `mixer volume 50` produced 4 reports (−22.73, −21.85, −21.07, −20.37 dB), and LMS crept to 57: each read-back was mistaken for a user change and pushed back. Fix: `apply_volume` records the read-back after setting, and opens a 500 ms window (`VOLUME_SETTLE_NS`) in which the listener only records. Re-measured: 50 stayed 50, 62 stayed 62, 0 reports. (A clean set-versus-read-back table was NOT obtained: the probe ran with sync live, so the engine overwrote its readings.) |
| UNMUTE IS NOT A LEVEL: when the Mac unmutes, sending LMS the device's level restores the volume | **WRONG** (measured 2026-10-10) | For squeezelite, LMS fades the level down over 0.3125 s (`SUPER::fade_volume`; `SqueezePlay::fade_volume` skips the fade only for baby/fab4), then mutes with gain 0. The engine then holds the device at its minimum, −63.5 dB. Unmuting sent `mixer volume 7`. Fix: `pushVolume` (now `VolumePush`) reads `mixer volume ?` (LMS stores a muted volume as negative), and sends `mixer muting 0` when it is negative. Re-measured: back to 42. Since 2026-10-14 only for the unmute key ALONE; a level moved while LMS is muted goes as `mixer volume N`, which unmutes LMS at N (`A MAC MOVE UNMUTES LMS AT ITS LEVEL`). |
| RESUME IS ONE AUDG: LMS sends a single volume when playback resumes | **WRONG** (LMS 9.1 source, 2026-10-10) | `StreamingController::_Resume` calls `fade_volume(fadeIn or FADEVOLUME)`; `SqueezePlay::fade_volume` skips the fade only for baby/fab4, so squeezelite gets `Player::fade_volume`: an `audg` every 0.05 s from 0 up to the volume. After a pause longer than `-C` (30 s) the device is closed, so these arrive while the monitor is opening it. |
| LMS SENDS VOLUME ON CONNECT: the player gets LMS's volume as soon as it connects | **TRUE — the 2026-10-10 verdict "WRONG" was itself wrong** (LMS 9.1 source + measured on the rig, 2026-10-14) | `Slim::Networking::Slimproto` hello handler, every HELO not needing an upgrade (SqueezePlay's `needsUpgrade` is empty): "make sure volume is set", `$client->volume($client->volume(), defined($client->tempVolume()))`. Measured with a silent stand-in player (`scratchpad/seqprobe/connect.py`): an audg ~5 ms after the HELO (after setd, setd, aude) at a first connect AND at each reconnect, carrying the SAVED level (not 0: 416 for volume 20.3, then 1458 for 33) and the sticky `seq_no` (0 for a new client object, kept across a reconnect). `Squeezebox::play` also re-sends it at each stream start, and `mixer` commands send it. So with `-V` every engine start or slimproto reconnect puts LMS's saved level on the device. Nothing it watches changed: watching from init is still right. Superseded text, kept for the record: `Squeezebox::play` re-sends it ("make sure volume is set") when each track starts, and `mixer` commands send it. A freshly connected player has no `audg` until then, hence the engine watches from init. |
| SETTING DVC SENDS AN AUDG AT ONCE: a `digitalVolumeControl` set from outside (`playerpref`) reaches the player only at the next track start or `mixer` command | **WRONG** (LMS 9.1 source, read 2026-10-11) | `Player.pm:77`: `$prefs->setChange( sub { $_[2]->volume( $_[2]->volume ); }, 'digitalVolumeControl')`, and `Squeezebox2::volume` sends `audg` with the pref as its adjust byte. `Prefs::Base::set` runs the change only when the value changes and the validator passes: `Player.pm:85-89` refuses a false value unless `hasDigitalOut` (squeezelite's `HasDigitalOut=1`, mapped in `SqueezePlay.pm`). `prefCommand` takes `_newvalue` "0" (`value || _newvalue` gives "0"). `status` returns it as `digital_volume_control`, an integer (rig, 2026-10-11), and Material shows a player at 0 as fixed at 100 (`server.js` dvc). |
| THE DVC HOOK SAVES A FADED VOLUME: changing `digitalVolumeControl` leaves the player's saved volume alone | **WRONG** (LMS 9.1 source, read 2026-10-11, after Simon's live report) | The hook is `$_[2]->volume( $_[2]->volume )` (Player.pm:77). `Client::volume` with no argument returns `tempVolume` when one is set (Client.pm:850), and with one but no temp flag SAVES it as the pref and clears the temp (Client.pm:842-845). LMS sets a temporary volume while it fades: `_Pause` fades to a temporary 0 (`fade_volume(-FADEVOLUME)`, Player.pm:427 `volume($endVol, 1)`), as do mute and sleep fades. So a fixed/variable change while one is in effect saves it, typically 0. LMS's own `stream_s` passes the temp flag (`volume($client->volume(), defined($client->tempVolume()))`, Squeezebox.pm:189); the hook does not: an LMS bug, which LyrionPlay hits on every device switch. On the rig 2026-10-11: prodmac46 at 50 (22:25Z), the FiiO left USB mid-track (23:26:55 local), the agent turned volume control back on (22:28:56Z), and LMS's saved volume was 0 at 22:30:40Z; the agent pushed no volume (agent.log). Which fade left that 0 was not seen. **REPRODUCED LIVE 2026-10-12** (0.3.1, DragonFly, Simon's OK): prodmac46 paused at volume 17, a switch to Fixed: the agent read 0.0 after the send (the pause fade's temporary 0, saved by the hook) and put 17 back; then played 8 s, paused, switched back to Device: 0.0 again, 17 put back. A muted player is safe: its negative volume survives the hook because the `mute` pref stops `Client::volume`'s clamp (Client.pm:831). |
| MIXER VOLUME ? IS THE SAVED VOLUME: `mixer volume ?` answers the temporary volume while LMS fades | **WRONG** (LMS 9.1 source, 2026-10-11) | `mixerQuery` answers `volume` from `$prefs->client($client)->get("volume")` (Queries.pm:2137); only bass/treble/pitch call the client's method. So it is the saved volume, negative while muted (what `VolumePush`'s unmute and `volumeRestore` both rely on). |
| A DB PROPERTY CAN BE STUCK: a device's `kAudioDevicePropertyVolumeDecibels` follows its volume, so `read_device_db` reading it first sees every change | **WRONG for the Melomania P100** (Bluetooth; measured 2026-10-14, read-only probe, Simon moving the macOS slider) | 816 change notifications; VolumeScalar on elements 1/2 moved 0.203-0.478 while VolumeDecibels read 0.00 dB in every one (settable, range -40..0 dB); ScalarToDecibels of the same scalars gave -31.87..-20.88 dB. So the engine saw no change and reported none (§B `MAC SLIDER LAG AND THE BLUETOOTH HEADSET`). |
| LMS DELAYS STATUS FOR A VOLUME CHANGE: a `mixer volume` reaches Material (any status subscriber) as soon as LMS takes it, so pushing the Mac's level more often makes Material follow a drag more closely | **WRONG** (LMS 9.1 source + measured on the rig, 2026-10-14) | `statusQuery_filter` (Queries.pm:3927) returns 1.3 for a `mixer volume` notification (1.4 for muting, 2.0 for stop, 2.5 for open/jump), and `Request::notify` (Request.pm ~2093) kills the subscriber's pending timer and sets it again at now + (that - 1): a 0.3 s TRAILING debounce, restarted by every change. Measured with a silent stand-in player and a cometd subscriber made as Material makes it (`/meta/connect` + `/slim/subscribe` `status - 1 subscribe:30`; `scratchpad/seqprobe/cometd.py`): one change reached the subscriber 517 ms after the command; 12 changes 150 ms apart (LyrionPlay's `LatestValueSender` pace) gave ONE update, 600 ms after the last; 8 changes 350 ms apart gave 8 updates, each ~0.5 s after its command. So at 150 ms Material stands still for a whole drag. The ~0.5 s per change is LMS's floor for every client. |
| SCALAR TO DB IS NOT THE DB PROPERTY: the HAL's `kAudioDevicePropertyVolumeScalarToDecibels` of a device's scalar gives the dB its VolumeDecibels property reads, so either can replace the other | **WRONG** (measured 2026-10-14, read-only) | MacBook Pro Speakers: scalar 0.385, VolumeDecibels -24.08 dB, ScalarToDecibels -39.03 dB, both live. DragonFly Black v1.5: VolumeDecibels -54.75 dB at scalar 0.021, ScalarToDecibels not supported. So a fix for `A DB PROPERTY CAN BE STUCK` cannot just read through the conversion: the speakers' levels (measured against VolumeDecibels, `VOLUME BOTH WAYS`) would change. The conversion is a LOOKUP (no device change), read 2026-10-14 for scalars 1.0/0.999/0.99/0.95/0.9/0.5/0.385: speakers 0.00/-0.06/-0.63/-3.18/-6.35/-31.75/-39.05 dB, the Melomania 0.00/-0.04/-0.40/-2.00/-4.00/-20.00/-24.60 dB: on both a straight line over the range, reaching the top exactly at full; the DragonFly has none (`kAudioHardwareUnknownPropertyError`). It is the speakers' dB PROPERTY that follows another taper. |
| UNIVERSAL IS NOT ROSETTA: A "universal" binary depends on Rosetta | **WRONG** (raised 2026-10-09) | A universal Mach-O carries a full native arm64 slice; Rosetta translates only x86_64-only code. Moot here anyway: tools are built from source as arm64-only (`TOOLS ARE BUILT HERE`). |
| MUTE HAS A WRITER ONLY WITHOUT A MUTE CONTROL: with `-V`, an LMS mute (gain 0, which is how LMS mutes, `Squeezebox2::volume`) leaves the DAC playing at its minimum dB, because `set_volume` keeps the samples at `FIXED_ONE` | **NO WRITER** (measured 2026-10-10, `squeezelite -l`) | `apply_volume` sets `kAudioDevicePropertyMute` whenever the device has one. DragonFly Black v1.5: `{"control":"main","db_min":-64.0,"db_max":0.0,"mute":true}`; MacBook Pro Speakers: `-63.5..0, mute true`; the FiiO has NO volume control, so it gets software gain and gain 0 is digital silence. Only a DAC with a volume control and no mute control would sit at its minimum, and upstream `output_alsa.c` `-V` does exactly that for every device (it never uses the playback switch except to unmute at init, line 891). Re-raise only with a named DAC whose `-l` shows `"mute":false` with a volume control. |
| THE OFF POLL COSTS NOTHING MEASURABLE: the monitor waking every 100 ms (`OFF_POLL_US`) while the output is off (the idle state with `-C 30`) costs energy | **WRONG** (measured 2026-10-10) | Engine PID 5610, idle 28 min (`mode stop`, output off, so the monitor polling): `top -l 3 -s 5 -stats cpu,idlew` gave 0.0% CPU and idle wakeups 793 → 796 in 5 s, about 0.6/s for the whole process (macOS coalesces the timers). |
| HOG MOVES THE DEFAULT OUTPUT: taking exclusive access to the macOS default output leaves it the default | **WRONG** (measured on macOS 26.7.1, 2026-10-10, silent probe: speakers idle, `DeviceIsRunningSomewhere` 0) | Hogging the MacBook Pro speakers made the FiiO the default 7-9 ms later; releasing put the speakers back 5-8 ms later, each with a `DefaultOutputDevice` notification (3 rounds). So with "Follow the macOS output" and exclusive mode (the default on a USB DAC), the engine's own hog at the first track moved the default, the agent's `AudioDeviceWatcher` restarted the engine on the speakers, the release moved it back, and so on. Fix: `Settings.resolveDevice(in:holding:)` stays on the device the engine holds (`heldDevice()`: `hogOwner == engine PID`); `followDeferred` (now `OutputFollow`) plus `tick` follow a different output chosen meanwhile once the engine lets go. |
| REMOVE WAITS FOR THE LISTENER: `AudioObjectRemovePropertyListener` returns at once | **WRONG** (measured 2026-10-10, silent probe on the hog-mode property) | Called while a listener call that sleeps 1 s was running, it took 1001 ms and returned after the call ended. `watch_volume`/`unwatch_volume` held `vrec.lock` across it, and `volume_listener` takes `vrec.lock`: a volume key at engine exit or at a device switch deadlocked. Fix: `vrec.watch` serialises the add/remove calls and the listener never takes it; `vrec.lock` is held only to copy `dev`/`ctl`. The fake HAL in `engine/tests/test_output_coreaudio.c` models this wait. |
| ATS LOCAL IS PLAIN NAMES ONLY: `NSAllowsLocalNetworking` lets the agent reach any LAN server name | **WRONG** (measured 2026-10-10 with a helper in a scratch bundle on the real Info.plist; the agent's `Bundle.main` is the app, so ATS applies to it) | `plex` and `192.168.1.234` loaded; `lms.lan`, `plex.home.arpa` and `example.com` failed -1022 before any DNS. With `NSAllowsArbitraryLoads` alone they passed ATS (-1003, no such host). With BOTH keys: -1022 again, because the local key voids the arbitrary one. The same binary outside a bundle had no ATS. Fix: `NSAllowsArbitraryLoads` only; `TransportSecurity` test forbids the local key coming back. The agent's only HTTP peer is the user's own LMS, over plain HTTP by necessity. |
| TESTING MACROS BY NAME: `swift test` under the Command Line Tools is deterministic | **WRONG with CLT 27.0 / Swift 6.4** (measured 2026-10-10) | About half of all test compiles failed with "plugin for module 'TestingMacros' not found" (repo: 5/6 then 3/8 serial with `-j 1`; a one-test scratch package 5/8, and 2/8 outside the tool sandbox), with `-plugin-path …/host/plugins/testing` on the command line. `-Xswiftc -load-plugin-library -Xswiftc …/plugins/testing/libTestingMacros.dylib`: scratch 12/12, repo 10/10. `build.sh` had piped `swift test` into `grep … \|\| true`, which hid both this and any real failure. |
| THE 4 S LINE SAW ONLY TIMEOUTS: agent.log's `took N s` line (0.2.7-0.2.8: the whole check timed against 4 s) shows a stalled server | **WRONG** (CODE-REVIEW 2026-10-11 (3), finding 2) | 4 s is the `players` request's own timeout (`URLRequest(timeoutInterval: 4)`), and a known server's check is that request plus `status`: only a request with no answer (4.00x s), or two slow ones, could cross it. A late answer (2-4 s, outlasting the 2 s tick: the stall rule's own case) wrote nothing; anti-run of 0.2.8's `LMSCheckLog`: answers of 2.6 and 3.4 s gave only "LMS: using …". And a run ended by the discovery after a timeout was written as "LMS checks of no server back under 4 s …, the slowest 4.0 s". Fixed: the server's answer time, over 2 s, one server per run. |
| A NEW ALBUM'S FLUSH CLEARS THE MARK: the delay mark a stop inside the open left set (CODE-REVIEW 2026-10-11 finding 3) reaches the next album | **NARROWER than logged** (scenario matrix on the 0.2.5 copy, 2026-10-11) | LMS starts every album with strm q, and `output_flush` clears `delay_active` unless the output is OFF. A stop, then another album, cleared it: no such scenario lost the first half on 0.2.5. Only with the idle release between the stop and the next album (strm q while OFF) did the mark survive to a later gapless rate change, which then lost its first half: 84 matrix failures on 0.2.5, all 84 with the idle release between. The 2026-10-11 named test skipped the album's strm q; its fix stands. |
| THE MATRIX IS FRAME-EXACT BUT ONE: the scenario matrix gives the same frames run to run, so a `MATRIX_SIG` diff between two builds is the change | **NARROWER** (CODE-REVIEW 2026-10-11 (4), 2026-10-11) | 3 parallel runs of one build: identical in all 26,250 scenarios. 0.2.10's first run differed from its next two in ONE: 7869, a synced start of DSD64 after a 48k device with a 200 ms rate delay, its music one IOProc call later (99 vs 100 segments, same music frames); serially (`MATRIX_ONE=7869`) 8 of 8 runs alike on both builds. A difference in a synced start: rerun before reading it as the build's. **NARROWER STILL (CODE-REVIEW 2026-10-11 (5)):** with the signature hashing every sample, two parallel runs of ONE build differed in 34 scenarios, and that build against 0.2.10 (the same machine code) in 37; all 51 are synced starts (of 170), every difference in the segment structure (none hash-only, so the hash adds no noise). Replayed serially, 3 runs each: 0.2.10 differed from itself in 13 of the 51. So a synced start can slip a call even alone, more under load. A difference there is the build's only if MATRIX_ONE reruns of both builds never give the same output; no other scenario has ever differed run to run. |
| AN ABSENT DEVICE AT START EXITS THE ENGINE: the engine starts while its device is away and waits for it (REVIEW 2026-10-10 finding 7, `volume_pending`) | **ONLY WITH -r** (upstream `output.c`, read 2026-10-11 while linking it into the suite) | `output_init_common` calls `test_open` unless `user_rates`, and `exit(1)`s when the device is absent. `-r` sets `user_rates`, and the agent passes `-r` only with a rate delay (`EngineArguments`). So with the default settings an engine started in the probe-to-start window exits at once and the agent starts it again; the absent-at-init path (and its tests, which now pass `-r`'s rates) needs a rate delay. Finding 7's fix stays; no writer changes. |
| EACH ENGINE TEST IS ITS OWN PROCESS: the engine suite's tests share one process, so a test that reads function-level statics (`ca_report_format`'s `said_*`) passes only while it runs first | **WRONG** (`CODE-REVIEW 2026-10-12` finding 9) | `main` in `engine/tests/test_output_coreaudio.c` `fork()`s every test (and the matrix every scenario) and runs it in the child; the parent never calls the engine, so each test starts from fresh statics. Only `what plays is reported once per change` and `the idle release is reported` call `ca_report_format`. |
| A SET ANSWERS AN EMPTY RESULT: a `playerpref` set answers no `result`, so `LMSClient.call` returns nil for a send that worked; and status's `mixer volume` is the temporary volume a fade sets | **WRONG, both** (rig + LMS 9.1 source, 2026-10-12) | `playerpref digitalVolumeControl 1` (the value it held, so no change hook ran; player stopped) answered `{"result":{}}`, so `call` gives `[:]`: nil means no HTTP answer, i.e. a stalled or gone server. `statusQuery` writes `mixer volume` from `$prefs->client($client)->get('volume')` (Queries.pm:4137), under `hasVolumeControl`, which is 1 for every player (Player.pm:482): the SAVED volume, negative while muted, as `mixer volume ?` (`MIXER VOLUME ? IS THE SAVED VOLUME`). |
| AN ORPHAN DIES AT ITS NEXT REPORT: the engine ignores SIGPIPE, so a `printf` to stdout (`ca_report_format`, `volume_listener`) cannot kill an engine whose agent died | **WRONG** (source, /code-review 2026-10-12 (3), 2026-10-12; a review cleared it on this wrong reason) | `signal(SIGPIPE, SIG_IGN)` (`engine/stream.c:804`) is inside `#if SUN`, which `squeezelite.h:73` defines for `__sun` only. `utils.c`'s `SO_NOSIGPIPE` covers sockets only, and the agent ignores only SIGTERM and SIGINT (`Agent/main.swift:137`). stdout is a `Pipe` to the agent (`main.swift:234`); stderr goes to the engine log, a file. So an engine orphaned by a crashed agent (`A CRASHED AGENT ORPHANS ITS ENGINE`) dies of SIGPIPE at its next stdout line. Since 0.3.x, `lyrionplay:format` makes that the next format change or idle release; before, it was the next Mac volume change on a `-V` device. Still NOT A FINDING: launchd restarts a crashed agent (`KeepAlive` `SuccessfulExit: false`, `LaunchAgent.swift:16`), and `stopOrphanedEngine` stops the orphan at once anyway. Not measured live. |
| A HOG DOES NOT HIDE THE VOLUME CONTROL: while another process holds a device exclusively and plays to it, `squeezelite -l` run from a separate process reports no settable volume for it, so a probe taken during a play (the agent's reconcile, the Settings window's) reads a saved "Device's own volume" as Software and drops `-V` | **WRONG** (measured 2026-10-12 on the DragonFly Black v1.5, /code-review 2026-10-12 (3) findings 1 and 2; silent: prodmac46 `mode stop`, zeros at the DAC's own 48k / 24-bit, so no relock) | A scratch probe set `kAudioDevicePropertyHogMode` on the DragonFly to its own PID. In its own view, `kAudioDevicePropertyVolumeScalar` (output, main) was present and settable. Meanwhile `/Applications/LyrionPlay.app/Contents/MacOS/squeezelite -l` gave `"exclusive_owner":<probe PID>` and `"volume":{"control":"main","db_min":-64.00,"db_max":0.00,"mute":true}`. A second probe did the same with an IOProc running (`DeviceIsRunningSomewhere` 1, 404 IOProc calls of zeros in 4 s), and `-l` again gave the volume. So holding a device and playing to it leave its volume control visible and settable to every process. Not run: an LMS play under the engine itself, or any DAC but the DragonFly. Re-raise only with a named device whose `-l` loses `volume` while held. |
| NO STRAY IDLE ON A REOPEN: `_ca_open` sets `ca.dev = kAudioObjectUnknown` and drops the output lock while it stops the old IOProc, so a `ca_report_format` tick during a mid-play reopen for a rate change sees the device closed and prints `lyrionplay:format idle` between two tracks | **WRONG** (source, 2026-10-12, /code-review 2026-10-12 (4)) | The rate-change reopen is `output.ca_reopen` -> `_ca_open()` on the slimproto thread (`slimproto.c:717-720`), and `ca_report_format()` is called later in the SAME loop iteration on the same thread (`slimproto.c:751`), so it can never run inside that window. The only other caller of `_ca_open` is the monitor thread (`monitor()`), which `_ca_open` starts only on `err` (the open failed, `ca.dev` already unknown). So the report has already said idle, correctly, before any monitor open. Re-raise only with a third `_ca_open` caller, or a report call moved off the slimproto thread. |
| LMS FIXED IS A FLAG, NOT A LEVEL: LMS's "Output level is fixed at 100%" holds the level the player had when it was set, so setting the volume first and then fixed keeps that volume (Simon's manual method, 2026-10-12) | **WRONG** (LMS 9.1 + squeezelite source, read 2026-10-12 at Simon's request: "Check on how LMS sets the fixed value first before deciding as with the dragonfly this seems to vary") | `digitalVolumeControl` is read in only two places: `Squeezebox2::volume` (squeezelite is a `squeezeplay` device, `Slim::Player::SqueezePlay`, which inherits it) and the settings page (`Settings/Player/Audio.pm`). Every `audg` carries the CURRENT volume's gain (`dBToFixed(getVolume(volume))`, 0 at volume <= 0) with the pref as its `adjust` byte (Squeezebox2.pm:275-315); LMS does not refuse a volume change on a fixed player, it only flags it. LMS's own text: "You can fix the volume control at 100% if you are using the volume control on your amplifier … This affects both digital and analog volume." squeezelite ignores the gain when `adjust` is 0 and plays at 100% (`process_audg`, slimproto.c:450, as upstream). Upstream `output_alsa.c` with `-V` then sets its mixer to 0 dB (`set_volume(FIXED_ONE)` -> `set_mixer(.., 0, 0)`, output_alsa.c:229-250): full, whatever the volume was before. So on squeezelite a fixed player's level is 100%; only an amplifier or a DAC's own knob sets it. LyrionPlay differs on purpose (§A2 `FIXED VOLUME LEAVES THE DEVICE ALONE`): Fixed runs without `-V` and never touches the device, so the DragonFly's own level in Fixed is whatever was last put on it. That is why it varies: LMS's level from the last *Device's own volume* engine (agent.log 17:29:53Z and 17:33:08Z put back a saved volume of 100, so 0 dB), muted at -64 dB after a pause fade (`FIXED SET UP WHILE PAUSED`), or what macOS restores when it is plugged back in (17:31:50-17:32:07Z). LMS keeps ONE saved volume per player (`mixer volume ?` reads the pref), so it follows a change of output (`ONE PLAYER PER DAC`). |
| DOP WORKS WITHOUT EXCLUSIVE MODE: DoP cannot reach a DAC in shared mode (*Follow the macOS output* with Exclusive off), since the engine sets an integer physical format only when it holds the device (`_configure`: `if (ca.hogged) set_physical_format`) and macOS's mixer would alter the DoP markers | **WRONG** (Simon, tested on the FiiO 2026-10-14) | My claim from the code, never tried on a DAC. Simon first saw no DoP through Follow; Follow's DoP switch was off ("My mistake it does work, i had. not enabled DoP on the MacOS player"). With it on, Exclusive off: engine-follow.log 22:55:03Z "exclusive: no", then "opened FiiO M11 Plus at 176400 Hz" and "at 352800 Hz" (DSD64, DSD128 as DoP), no "exclusive"; Simon: it works. Never tie DoP to Exclusive or take it off Follow on this belief. Confirmed again on 0.4.4 ("DoP works on follow without Exclusive mode"). Not tried: a device whose macOS volume is applied in software below full |
| THE MAC'S NAME LOOKUP STALLS: `Host.current().localizedName` (NSHost) can block, so `PlayerSettings.macName`, read in every `Settings()` decode and for each unsaved device row at every Settings redraw, can stall the window or the agent | **WRONG** (measured 2026-10-14 on prodmac46, /code-review 2026-10-14 finding 5) | A scratch Swift binary timed it five times in one process: 3.1 ms the first call, then 0.05-0.12 ms each; `SCDynamicStoreCopyComputerName` 0.06 ms; both gave "prodmac46". Not measured: a Mac with no network or a slow DNS. Re-raise only with a measured stall. |
| A STATUS CHECK HOLDS UP A PUSH: `LMSClient.playerStates` asks `status` for each player in turn, so with several players a Mac volume push waits behind the check | **WRONG** (source, 2026-10-14, /code-review 2026-10-14 finding 7) | The check runs on its own detached task (`refreshLMS`), and each push is its own `URLSession.shared` request from that player's `LatestValueSender` (`PlayerSlot.volumeSender`); nothing orders the two (no lock or queue in `LMSClient.call`; URLSession opens several connections per host). The calls in turn only delay what the menu shows, by about one LMS answer per extra player (38-49 ms, §B MAC SLIDER LAG), in a check every 5 s. Re-raise only with a push measured waiting on a check. |

### B. KNOWN-OPEN AND ACCEPTED — do not re-report as new

- **ONE PLAYER PER DAC — BUILT in tree 2026-10-12 to the approved plan
  (`~/.claude/plans/immutable-purring-hoare.md`), NOT installed, NOT live-tested** (§C `PLAYERS AND
  FIXED BUILT 2026-10-12`; PARKED 2026-10-10). The 2026-10-12 reason and requirements, after
  `CODE-REVIEW 2026-10-12 (7)`:
  - **Why:** "Its a mistake having all of the 3 options on one instance of Squeezelite … LMS sees it as
    one player and its saved volume or paramters are inherited to what ever output is chosen." His
    examples: lower the volume on the macOS output, change to the DragonFly, and the volume goes with
    it (and Fixed is set at that volume); from a device at Fixed 100% to the Mac speakers, the speakers
    play at 100%. "Its all got too complicated."
  - **Shape:** "each DAC or output device needs its own Squeezlite instance", which the user can
    enable or disable: "Follow the macOS output" (not the MacBook speakers as a player of their own),
    then each additional device detected.
  - **Options per player, as today's rules:** a device with a volume control, the 3 options; a DAC
    with none, 2; the macOS output, 2.
  - **No migration:** "We dont need to carry existing settings from a previosu install we can start
    again no migration needed."
  - **Settings page:** "should at first show each device that is seen by squeezelite with a settings
    button (cog icon woud be nice) next to it that when clicked on show the same settings we have now
    to change it for that squeezelite."
  - **Answers, 2026-10-12 (Simon picked each recommended option):** the list is *Follow the macOS
    output*, then every device squeezelite lists except the Mac's built-in speakers/headphones (reached
    through *Follow the macOS output*); HDMI, Bluetooth and AirPlay included if listed. Each row has the
    name, an on/off switch and the cog; *Follow the macOS output* on by default, the others off. Per
    player (behind the cog): name, exclusive, DoP, LMS volume, silence on a rate change. Shared, set
    once: LMS server, release time, resampling quality, log detail. The menu bar panel shows one line
    per player that is on: name, device, connected or not, and what it is playing.
  - **Fixed:** must work on a DAC with a volume control (the DragonFly) when set up while paused,
    "as its going to be setup wilst pasued more often than not": NOT left at 0 / muted (`FIXED SET UP
    WHILE PAUSED`); and it must keep working on DACs with no volume control. Simon: "If I was setting
    a player to fixed volume manually in LMS I would set the volume to the limit I want then chnage
    the settings to fixed." Earlier the same day he agreed Fixed = the DAC at 100% ("it is for using
    line level out to an amplifier and you need 100%"). LMS and squeezelite themselves play a fixed
    player at 100% (§A3 `LMS FIXED IS A FLAG, NOT A LEVEL`). **DECIDED by Simon 2026-10-12: Fixed
    HOLDS THE LMS VOLUME** (§A2 `FIXED HOLDS THE LMS VOLUME`).
  - **UNVERIFIED report:** the macOS output's volume "seems suspect when I just tried it and did not
    map 1:1 to LMS volume at all" (2026-10-12; device, mode and levels not recorded, not measured).
    The numbers are matched by dB, not by percentage (`LMSVolume`, the SqueezePlay curve: agent.log
    17:35:12-17:37:05Z, the speakers' -63.5 dB minimum = LMS 7, -28.78 dB = LMS 42). Simon, the same
    day: "there was a very large delay in the change to LMS so that may need more investigation" —
    OPEN, not investigated. On 2026-10-10 the lag was "slight" (the 150 ms `LatestValueSender`
    throttle plus Material's redraw); where a large delay comes from (the engine's report, the
    agent's sender, LMS, Material) is not known.
  - **MAC SLIDER LAG AND THE BLUETOOTH HEADSET — reported by Simon 2026-10-14, OPEN, nothing changed**
    ("when in follow macOS the lag between changing levels using the macOS slider to material is quite
    substantial"; "when using a BT headset via macOS using the macOS slider didnt move material at all,
    but using materials slide adjusted macOS levels, but they get out of sync"). From the logs only:
    - **Slider lag — CAUSE MEASURED 2026-10-14 13:59:47-14:01:32 local, 0.4.1, the Melomania under Follow**
      (Simon: "it works but very laggy in its response"; Simon dragged the macOS slider, nothing playing;
      debug log for the window only, settings.json restored byte-identical after; read-only watchers in
      the scratchpad: the headset's scalar every ~18 ms during a drag, LMS's `mixer volume ?` polled):
      - Mac -> LMS is fast once reported: report 14:00:41.249, LMS's echo audg at the engine 8 ms later
        (41.257), LMS at 37 by the next poll (41.288).
      - LMS answers each `mixer volume N` with TWO audgs (~11 ms apart); each runs `apply_volume`, which
        puts LMS's rounded level back on the headset mid-drag (59.743 and 59.762: -18.62 dB while the
        user was going up) and opens `VOLUME_SETTLE_NS` (500 ms).
      - In that window every move is recorded as the engine's own: drag up 59.09-59.99 (-20.84 to -16.50
        dB), 51 headset changes, 2 reports (59.09, 59.73), LMS ended at 62 (-18.6 dB). Drag down
        18.04-18.81 (-16.45 to -25.40), 2 reports, LMS 50 (-24.6). Last move 22.95-23.14: reported
        -28.64 (LMS 42), then -33.08 inside the window, never reported: LMS left at 42 (-29.1 dB) with
        the headset at -33.1 dB. That is the lag and the "out of sync" (Simon, earlier the same day).
      - So: during a drag LMS gets a level about twice a second, the headset is pulled back toward each
        stale one, and a drag that ends inside the window leaves LMS behind for good. The 500 ms window
        exists for the speakers' coarse read-back (`READ-BACK IS NOT THE LEVEL SET`: without it LMS crept
        50 -> 57) and LMS's mute fade. Options put to Simon; he chose the first, skipping LMS's echo
        ("yes as long as this doesnt break functionality elsewhere"): built in tree, then REJECTED (a
        Material nudge not heard: §C `LMS'S ECHO IS NOT PUT ON`), REPLACED by §C `THE DEVICE STAYS WHERE
        THE MAC PUT IT` (2026-10-14, INSTALLED as 0.4.2, VERIFIED LIVE).
        **Remaining lag, 0.4.2** (Simon: "all works but we still have lag to materail from the macs
        volume. This may be unavoidable but function wise it works better"): MEASURED the same day, it is
        LMS's status debounce (§A3 `LMS DELAYS STATUS FOR A VOLUME CHANGE`): ~0.5 s per change is LMS's
        floor, and at the agent's 150 ms pace each push restarts it, so Material stands still for a whole
        drag and moves ~0.6 s after it ends. Pushing at most every 350 ms gave an update per push, each ~0.5
        s behind. **DECLINED by Simon 2026-10-14** ("leave it and close this"): the agent keeps
        `LatestValueSender(interval: 0.15)`. CLOSED. NOT A FINDING from now on: Material standing still
        during a Mac drag and following ~0.6 s after it ends, the push pace, LMS's status debounce. Re-raise
        only if Simon asks. The live check owed: drag the macOS slider
        on the headset or the speakers; Material follows during the drag and ends where the slider stops.
      Earlier, from the logs only: every engine report (`volume_listener` "device volume changed outside LMS") was
      logged by the agent in the same second, but the agent logs BEFORE `client.call`, so LMS's receipt
      is not timed. During a drag the engine reported at most one change per ~0.6-0.75 s (engine-follow
      2026-10-12 21:26:15.08/15.80/16.55/17.24 local; 2026-10-13 10:28:58.49/59.07). SUSPECTED, NOT
      MEASURED: LMS answers each `mixer volume N` with an audg, `apply_volume` puts LMS's (integer, so
      rounded) level back on the device mid-drag and opens `VOLUME_SETTLE_NS` (500 ms), in which the
      user's further moves are recorded as the engine's own and never reported; a drag that ends inside
      that window leaves LMS on an older level. Needs a debug-log run (apply_volume's LOG_DEBUG) with
      Simon dragging the slider, nothing playing. LMS answered `mixer volume ?` in 38-49 ms (10 of 10,
      2026-10-14 12:15Z, over Tailscale 100.71.35.108); the agent's checks timed out at 4 s several times
      that morning, and a push stuck behind one waits (one send at a time).
    - **Bluetooth — CAUSE MEASURED 2026-10-14 12:29-12:33Z** (Simon connected the Melomania P100; a
      read-only listener probe in the scratchpad, Simon moving the macOS slider): its volume is two
      channel controls (elements 1 and 2, no main), each with a settable VolumeScalar AND VolumeDecibels.
      macOS announced every step (816 notifications: VolumeScalar and VolumeDecibels on e1/e2, Mute,
      VirtualMainVolume/Balance), the scalar moved 0.203-0.478, but **VolumeDecibels read 0.00 dB in
      every one** (the HAL's own ScalarToDecibels gave -31.87 to -20.88 dB). `read_device_db` reads
      VolumeDecibels first, so the engine always sees 0.00, never a move over `VOLUME_MOVED_DB`, and
      reports nothing: engine-follow.log has no "changed outside LMS" line after the engine moved to the
      headset (13:29:09 local). §A3 `A DB PROPERTY CAN BE STUCK`. LMS -> headset works (Simon), through
      `set_control_db`'s VolumeDecibels write. **Round trip MEASURED 12:40:10-13Z** (Simon: "ok"; nothing
      playing, LMS checked `stop` before each write, scalars put back exactly after: 0.478 both, LMS
      volume 51 before and after, no engine report): writing VolumeDecibels -38/-30/-24/-18/-12/-6 dB on
      elements 1 and 2 landed at scalar 0.050/0.250/0.400/0.550/0.700/0.850, exactly the HAL's
      DecibelsToScalar of each, and ScalarToDecibels of each gave the written dB back exactly (a linear
      taper, scalar = (dB + 40) / 40); the dB property read 0.00 after every one. So on this device the
      writes and the conversion agree; only the dB property's READ is broken. **FIXED the same day,
      INSTALLED as 0.4.1** (§C `A STUCK DB PROPERTY FIXED`); VERIFIED LIVE by Simon ("it works"):
      the macOS slider on the headset under Follow moves Material.
  - **PERFECT SYNC: SIMON'S REQUIREMENTS — 2026-10-14, design NOT started** (after `LMS'S ECHO IS NOT
    PUT ON` was rejected). Simon: "As long as the rounding to make the mac volume + or - to the
    nearest 2db gain on release of materials slider then its fine. What I dont want is to change again
    after a track change as thats bad. If the mac goes up in 2db incremnets we need to ensure LMS maps
    as close as it can."
    - ACCEPTED: on release of Material's slider the device lands on its nearest hardware step.
    - REQUIRED: no change of the heard level at a track change. LMS re-sends the volume at every track
      start (`LMS SENDS VOLUME ON CONNECT`); today that re-send is put on the device, so after a Mac
      slider move the device is moved to LMS's rounded level (up to 0.25 dB above LMS 25, 0.74 dB
      below, plus `dBToFixed`'s rounding) at the next track. Also true of 0.4.1.
    - REQUIRED: Mac -> LMS as close as LMS can map (already the nearest whole volume, `LMSVolume`).
    - **Client volume steps, VALIDATED 2026-10-14 against the rig's installed copies:** Material 6.4.13
      (`material-deferred.min.js` from plex:9000): *Volume step* offers 1%, 2%, 5%, 10%, default 5%
      (Simon thought 3%: there is no 3%); it applies to the +/- buttons, keys and wheel (`adjustVolume`);
      the slider itself is `step="1"`, any whole volume. Classic and Default skins (SqueezeJS,
      `Base.js` `setVolume`): +/- buttons step 2; the volume bar has 11 positions (0, 10 ... 100).
    - LMS's resolution: a whole volume is 0.49 dB above 25 and 1.48 dB below (SqueezePlay curve).
    - **NO STEP COUNTING — Simon 2026-10-14** ("we are not coutning steps thats not practical"): do not
      measure or tabulate each device's hardware volume steps, and do not design on them. The design
      works from the level the device reports, whatever its steps.
    - **NO DIP ON A MAC UNMUTE — Simon 2026-10-14** ("i have not heard any dips whilst unmuting that
      does not affect the macs volume in my tests"): LMS's fade back up after a Mac unmute is not heard
      as a dip; not to be measured or designed around. Re-raise only with a dip heard and named.
    - **MEASURED 2026-10-14 on the rig (LMS 9.1.2), silent** (Simon: "yes run it"): a stand-in player
      (`scratchpad/seqprobe/probe.py`, test MAC 02:00:4c:50:53:51, HELO as squeezelite, no audio;
      forgotten with `client forget` after) logged every audg for `mixer volume` commands:
      - **Every audg carries the sequence number** (22 data bytes; 0 from the connect). `mixer volume
        41 seq_no:7` -> seq 7; a later `mixer volume 42` with none STILL carries 7 (sticky, as
        Commands.pm:560 reads). So a seq marks the commands LMS took up to that point, not who sent
        the level: a Material change after the agent's last send carries the agent's number.
      - **Two audgs per change, ONE when the volume is unchanged** (`mixer volume 37.6` twice: the
        second gave one audg; the pref hook runs only on a change). ~11-14 ms after the command.
      - **A fractional volume is kept and sent:** `mixer volume 37.4` -> `mixer volume ?` 37.4, gain
        1872; 37.6 -> 1894.
      - **Adjacent volumes can share a gain:** 41 and 42 both gave 2304 (dBToFixed's 8 bits between -30
        and 0 dB: 9/256 for both); 40 gave 2048. So between about -30 and -20 dB LMS's own level moves
        in ~1 dB gain steps whatever the slider says, for every squeezelite.
    - **VERIFICATION 2026-10-14** (Simon: "verify this will work with out any other issues or volume
      snapping to another volume at track or album change"), from the LMS 9.1 source
      (`scratchpad/lmssrc`, branch public/9.1 at 582a1b2, Slim/ only) and the rig:
      - **Every path that sends a level** (`grep` of `volume(`/`fade_volume` in Slim/): the hello handler
        (every connect and reconnect, measured); `Squeezebox::play` at every stream start (a gapless
        next track when the decoder reaches it, before it is heard; an album or a seek from stopped);
        `_Stream` from STOPPED also `$player->volume(abs pref)` first (the master's level with
        `syncVolume` in a group), and `volume(0,1)` when the player's `fadeInDuration` is set, faded up
        at `_Playing`; `_Pause` fades to a temporary 0, `_Resume` sets 0 then fades up, its last step
        `volume(endVol, 1)` = the saved level exactly (Player.pm:427); mute/unmute fades
        (Commands.pm:607); sleep fade (Commands.pm:3211); alarms; the `volume` pref hook (the twin
        audg). Crossfade and LMS's short fades are the player's own sample fades (strm), never audg.
      - **The snap today (0.4.1 and before):** after a Mac move the device sits between LMS's whole
        volumes; each of those paths puts LMS's saved level back. Largest, every device level -74..0
        dB in 0.01 dB through the agent's mapping and LMS's arithmetic: 0.74 dB between -30 and 0 dB (the 8-bit gain), 0.25 dB from -37
        to -30, 1.75 dB below -37 (LMS 1 at -72.25 dB for -74). Not a reset: Simon, 2026-10-14: "it
        doesnt resest the volume", "the mac or LMS volume is not reset in the UI", "it will start at
        the last saved volume level". The Mac slider moves by that rounding only.
      - **The echo can be named EXACTLY without `seq_no`:** the agent's mapping is the nearest whole
        volume by dB (`LMSVolume.volume(forDB:)`), and LMS's gain for it is plain arithmetic
        (`getVolume` with SqueezePlay's parameters, then `dBToFixed`): computed here it matched all 7
        gains the rig sent (40, 41, 42, 37.4, 37.6, 20.3, 33), and no whole volume comes within 2e-4
        of a rounding boundary, so a libm difference cannot flip one. Whole volumes 41/42, 44/45, 47/48
        share a gain (LMS's resolution, on every squeezelite).
      - **DECIDED by Simon ("yes") and BUILT 2026-10-14, §C `THE DEVICE STAYS WHERE THE MAC PUT IT`** (as
        built: an answer to ANY report, not only the newest, sets LMS's level, so a failed send no longer
        moves the device at the next track); proposed as: (1) each report keeps its expected gain and the device's
        own scalars; an audg EQUAL to a recent report's expected gain is its echo: nothing is put on,
        and that pair (gain -> scalars) is kept; (2) a level whose gain is the pair's gain is put on as
        those scalars (exactly where the Mac left it), any other as today; (3) nothing is written when
        the target equals the one last put on or adopted (track starts, album starts, connects, the
        twin); (4) at an engine start, the connect level is adopted when it equals the expected gain of
        the device's current level. Residuals to state: a move inside the 500 ms settle window is not
        reported (LMS's number lags; no snap); a failed send leaves LMS's older level to be put on at
        the next track; a level LMS changed while the engine was down is put on at the start (as
        today); exact scalar restore unproven on Bluetooth until live.
      - **Found on the way, existing since 0.2.0:** (1) after a Mac MUTE, LMS's fade-out (`mixer
        muting 1`, ~0.31 s of audgs; measured on the stand-in: 2304, 1656, 1128, 530, 167, 53, 17, 0)
        reaches `apply_volume`, which unmutes the device for each step above 0 (`mute = left == 0 &&
        right == 0`), so the fade-out may be heard after the key: **ACCEPTED by Simon 2026-10-14**
        ("first one isnt a problem and I accept it if does happen"); do not report or fix it. (2) a Mac
        LEVEL move while LMS is muted sent `mixer muting 0` (VolumePush), so LMS faded to its own saved
        level, not the Mac's: **CONFIRMED by Simon** ("2nd one does happen, so we need to fix that and
        it should unmute LMS and move it the correct position"), **FIXED in tree** (§C `A MAC MOVE
        UNMUTES LMS AT ITS LEVEL`).
  - **SYNC GROUP: FIXED NOT SHOWN IN MATERIAL — reported by Simon 2026-10-14, UNVERIFIED, stood down
    by Simon** ("lets stand down for now. I will try to replicate another time"): a player switched from
    *Device's own volume* to Fixed after its sync group was made did not show as fixed in Material until
    it was ungrouped and added again. Checked: every Fixed change of 0.4.0 reached LMS (agent.log, no
    refusal); LMS 9.1 `statusQuery` reports each player's own pref (Queries.pm:4188-4190; nothing in
    Sync.pm shares it); Material reads it per player (server.js:544, groupvolume-dialog.js `updatePlayer`).
    The moment was not found in the logs (grouped 2026-10-12 ~20:00-20:12Z by the engines' synced
    starts; no Fixed change logged in that window).

  The 2026-10-10 question (Simon: "is it possible that multiple
  dacs connected could be seen as multiple players each with their own mac address and have unique
  name based on the dacs connected?"). Feasible: one engine per device, each with its own `-o`,
  `-m`, `-N` and `-f`; the engine needs no change. Simon's answers:
  - today's player stays exactly as it is, and a "More players" list adds one per device (on/off
    plus a name), off by default;
  - the default name is the DAC's name only [SUPERSEDED by Simon 2026-10-12: "Use the macs name
    followed by attached device for playernames" — a device's player is "<Mac's name> <device's
    name>", e.g. "prodmac46 AudioQuest DragonFly Black v1.5" (`PlayerSettings.defaults(for:)`,
    pinned in PlayerCoreTests `defaults`); *Follow the macOS output* stays the Mac's name];
  - when the main player follows the macOS output and that output is a DAC with its own player,
    the main player uses the built-in output.

  **THE OLD PLAYER CARRIES ON — DECIDED by Simon 2026-10-12** (asked: "is this now or on every app
  update?", then "Keep the old ID"). The first time *Follow the macOS output*'s identity is made, it
  copies 0.3.x's `mac` and `player-name` (`PlayerIdentity.adoptOldPlayer`, called in the agent's
  `makeSlot` for `PlayerKey.follow` only; agent.log "<name> carries on as the earlier version's player
  <mac>"), so LMS keeps the same player: name, volume, favourites, sync; nothing left disconnected.
  Copied, not moved; never read again once `players/follow/mac` exists, so a later rename LMS writes
  stays. An invalid or missing old MAC gives a new player and takes no old name. New IDs happen only
  for players that never existed (device players), and only once: IDs live in
  `~/Library/Application Support/LyrionPlay/players/`, which install.sh never touches (it replaces the
  .app only). Tests `theOldPlayerCarriesOnAsFollow`, `noOldPlayerMeansANewOne`; 3 mutants (adopt over
  the player's own MAC, name not copied, an invalid old MAC adopted), each killed.

  Identity per player is keyed by device UID. Measured 2026-10-10: the DragonFly's UID carries its
  USB serial (`AQDFBL0100009556`), not its port (locationID 0x1100000), so a port change keeps the
  player; the FiiO's (`…:3fa90f5:1`) is unchecked. The design keeps the rules in PlayerCore as
  pure functions:
  - `mainDevice`;
  - `extraAssignments`;
  - `EnginePlan`, with stops before starts;
  - a per-player volume sender, because the one `LatestValueSender` would drop another player's
    push.
- **FIXED SET UP WHILE PAUSED — CONFIRMED by Simon 2026-10-12; FIXED the same day by `FIXED HOLDS THE LMS
  VOLUME` (the held level is put on at the engine's start, unmuted), INSTALLED as 0.4.0, VERIFIED LIVE
  2026-10-12 20:16Z on the DragonFly** ("held at -25.6 dB (was -64.0 dB, muted)", HAL -25.65 dB unmuted
  while paused; §C `PLAYERS AND FIXED BUILT 2026-10-12`) (`CODE-REVIEW 2026-10-12 (7)` findings 1 and 2; `apply_volume`, `kAudioDevicePropertyMute`,
  `EngineArguments` `-V`, `fixedVolumeNeverTouchesTheDevice`, `output_close_coreaudio`, `unhog`). With
  *Device's own volume*, LMS's pause fade ends at gain 0, which `apply_volume` puts on a DAC with a volume
  control as `db_min`, muted (output_coreaudio.c:474-476). Nothing undoes it when the engine restarts
  without `-V` (a switch to Fixed or Software), at the idle release, or at exit, so Fixed set up while
  paused plays into a muted DragonFly. Simon: "1 does happen". Two fixes were BUILT and REVERTED by Simon
  the same day (not kept in the repo):
  - the exiting `-V` engine put back LMS's last level that held 200 ms (a fade steps every 0.05 s);
  - Fixed passed `-a <f>:<e>:1`, and the engine set a DAC's own volume to 100%, unmuted.
  Simon: "I am concerned this is going to open up more issues as you have changed more than was
  planned", then "we need to stop this work and revert back to the last version". Do not re-propose
  either as a patch to the one-player design; the requirement is solved in `ONE PLAYER PER DAC`. A Quit or
  Off while paused leaving the DAC muted: Simon, "thats the same for anything with LMS". Software's case:
  §A2 `SOFTWARE AFTER A PAUSED -V DAC`.

  The agent holds one `EngineSlot` per player. Until built, "only one player per Mac" is not a
  finding.

- **Simon installed LyrionPlay himself with install.sh** (2026-10-09). This was the first real run
  on a login keychain, and the first run of INSTALL.md. It worked: "LyrionPlay Signing" was
  created in his keychain with no prompt reported, the player connected as "prodmac46" on the
  MacBook Pro speakers, and later `build.sh --install` updates reused the certificate.
- **Not yet confirmed on the new install:**
  - the Settings window: USED by Simon (agent.log 2026-10-10 08:53:49Z "settings changed:
    restarting the engine for AudioQuest DragonFly Black v1.5", his move to the DragonFly), so it
    opens and saves; its other controls are unseen;
  - ⌘Q with the panel open (`A SHORTCUT QUIT THE MENU`);
  - Quit stopping the player;
  - the icon in a real menu bar.
- **A fresh install means a new MAC address, so a new LMS player** named after the Mac. That
  player needs "Output level is fixed at 100%" again, for the FiiO. [Since `FIXED AT 100% PER DAC`
  (installed as 0.3.0 2026-10-11): the FiiO's "LMS volume" set to Fixed in the app does it.]
- **FIXED AT 100% PER DAC — INSTALLED as 0.3.0, 2026-10-11 22:25Z; the switch both ways VERIFIED LIVE in
  0.3.1 on the DragonFly, 2026-10-12 (below); the rest of the list below still owed** (Simon: "build
  and install", "Yes, 0.3.0"; 0.2.11 -> 0.3.0 with `bump-version.sh minor`; `build.sh --install`,
  suite PASS inside it; nothing playing, the FiiO back on USB at 22:24:50). install.sh "version 0.3.0
  (was 0.2.11)"; agent.log "agent started: LyrionPlay 0.3.0 (202610112324)", engine on the FiiO,
  "LMS: using Simons Music". First checks: prodmac46 connected, stopped, `digital_volume_control` 1,
  volume 50, which matches the FiiO's saved `"volume": "software"`: nothing sent, no "LMS volume"
  line (correct). Simon picks Fixed for the FiiO in Settings to get fixed volume back.
  **LIVE REPORT, Simon 2026-10-11:** "setting it back from fixed doesnt work it stays fixed", then
  "it works for the Fiio fine" (the DragonFly fails: there a mode change restarts the engine for
  `-V`, and LMS's volume drives the device). agent.log and LMS: every switch back DID reach LMS
  (22:28:56Z, 22:29:38Z; `digitalVolumeControl` 1 at 22:30:40Z), but LMS's saved volume was 0, so
  the DragonFly in device mode went to its minimum and muted: most likely what read as "stays fixed"
  (Simon did not say which screen element; not confirmed). Cause and fix: `THE DVC HOOK SAVES A
  FADED VOLUME`; the put-back INSTALLED as 0.3.1 and VERIFIED LIVE 2026-10-12 (below). Simon's guess, "squeezelite sets volume
  to 0 when stopped", is LMS's pause fade (a temporary 0) saved by the hook.
  Live checks owed, each a sound test (ask the player; FiiO knob down first):
  - FiiO set to Fixed and saved: agent.log "setting it to fixed at 100%" within ~2 s; LMS
    `playerpref digitalVolumeControl ?` 0; Material shows the player fixed at 100; engine.log
    audg `adjust: 0` (debug log);
  - changed back in Material: put back within ~5 s, one agent.log line;
  - DragonFly (device volume) after the FiiO: "turning volume control back on", the LMS slider moves
    the DragonFly again; the DragonFly as Fixed: its level stays where the Mac set it. [ANSWERED
    2026-10-12: not after a switch made while paused; it stays muted at its minimum, confirmed by
    Simon: `FIXED SET UP WHILE PAUSED`.]
  - the put-back: **VERIFIED LIVE 2026-10-12, 0.3.1** (Simon: "build and install", "continue",
    output "DragonFly"; 0.3.0 -> 0.3.1 with `bump-version.sh patch`, `build.sh --install` suite PASS,
    install.sh "version 0.3.1 (was 0.3.0)", agent.log "agent started: LyrionPlay 0.3.1
    (202610120907)"). Mode checked before each command; settings.json backed up and restored
    byte-identical (`cmp`), no engine restart on the restore. (1) prodmac46 found PAUSED (Simon's
    Dean & Britta queue, volume 17); DragonFly set to Fixed in settings.json at 08:09:12Z: engine
    restarted without `-V`, then 08:09:18 "setting it to fixed at 100%" and "LMS saved its faded
    volume (0.0) … put back: mixer volume 17"; LMS fixed, volume 17. The restart STOPPED the paused
    player (LMS, on the reconnect). (2) `play` of the same queue 8 s (DragonFly in Fixed, its level
    where LMS 17 left it), `pause 1`, then Device at 08:09:56Z: 08:10:02 "turning volume control back
    on" and again "(0.0) … put back: mixer volume 17"; LMS volume control on, volume 17, stopped.
    Queue after: 14 tracks, index 0, as before (the paused place in track 1 lost to the restart in
    (1)). Not checked: the DragonFly's hardware level after the put-back (no read of it), and
    Material's slider (not looked at).
- **THE VOLUME KEYS ON A FIXED DAC — CONFIRMED by Simon 2026-10-12, wording FIXED, CLOSED** (`CODE-REVIEW
  2026-10-12` finding 1). Simon: "Volume keys control what MacOS it set to use in the OS audio widget, mute
  does however mute LMS". So the Fixed caption's "the Mac's volume keys set it" held only for a DAC chosen
  as the macOS output; on the rig that is the MacBook Pro Speakers (status.json `"default": true`), not
  the DragonFly the player uses. FIXED (0.3.2: "set it on the device, or with the Mac's volume keys while
  it is the Mac's sound output"), then REWORDED by Simon's decision, 2026-10-12: "You dont need the mac os
  part of the warning when its fixed on a DAC this will confuse things. We do however need to be clear
  that VOlume keys only work when outout is MacBook Speakers or Follow OS." Now: Fixed's caption has no
  volume-keys part ("leaves X's own volume alone."); *Device's own volume* and *Software*, on a device with
  a volume control, add "The Mac's volume keys work only when the output is the Mac's built-in speakers or
  Follow the macOS output." WRONG BELIEF, mine, corrected by Simon the same day ("Voluime keys only affect
  MacOS output"): "LyrionPlay passes the volume keys to LMS, only with the device's own volume". LyrionPlay
  never sees a key; the keys change the macOS output's level in every mode. With `-V` the engine watches
  ITS OWN device's level (`watch_volume`) and passes any change of it to LMS, so a key reaches LMS only
  when that device is the macOS output. The note first sat under *Device's own volume* only, from that
  belief; INSTALL.md the same (feature line, *Device's own volume*;
  *Fixed at 100%*: "on the DAC or your amplifier"), the `VolumeMode.fixed` comment too. "Built-in
  speakers" for Simon's "MacBook Speakers" (the device name differs per Mac). WORDING DECIDED: never
  re-argue it; a complaint means change it. Pages regenerated. Then (same day) the non-fixed captions
  lost "LMS's own fixed-volume setting … follows this choice" (Simon: it read as the DAC's volume being
  fixed); see §A2 Settings window for the text. README.md's feature line ("your Mac's volume keys move each other") was left for the merge to
  main, then corrected in the `DOCS PASS 2026-10-12` at Simon's request (same keys wording). MUTE: Simon reports the mute key mutes LMS; which device and mode he
  used was not said, and how it reaches LMS when the player's device is not the macOS output was not
  traced. CLOSED by Simon 2026-10-12 ("as I said volume keys do not alter the dac in my test so this can
  be closed"): no live test owed. Not a finding: the keys during exclusive playback on a DAC that is the
  macOS output (`HOG MOVES THE DEFAULT OUTPUT`); the wording ("while it is the Mac's sound output")
  holds either way.
  - **Why two-way volume "worked before" (Simon asked, 2026-10-12; "that makes sense"):** the code is
    unchanged. The engine watches the volume control of the device it PLAYS TO and passes any change to
    LMS; the keys move only the macOS output. `VOLUME BOTH WAYS` was measured on the speakers, which were
    both. With the DragonFly playing and the speakers the macOS output, the keys move the speakers and the
    engine sees nothing. agent.log 08:46:50-59Z: four MUTE reports from the DragonFly (-48.83 dB = LMS 17,
    -64.00 dB its minimum), LMS muted and unmuted, no level report; why the mute reached the DragonFly
    was not traced. The keys on the DragonFly as the macOS output were not tested: CLOSED by Simon, above.
- **GitHub:** Simon created https://github.com/SimonArnold002/LyrionPlay (public, 2026-10-09).
  The local folder became a git repo on 2026-10-11: the whole project pushed to `dev` as `7faf2f8`
  (135 files, compiled test binaries and this ledger included, Simon's choice); `main` holds only the
  initial README. README.md (credits squeezelite's Adrian Smith and
  Ralph Irving, as Simon asked), LICENSE (MIT, CrystalGipsy, excluding engine/), INSTALL.md,
  NOTICES and UPSTREAM.md name the repo as the source.
  - GitHub API, 2026-10-10: the repo holds one file, `README.md` (pushed 2026-10-09 23:36Z), and
    has no releases; Pages is switched on (`has_pages: true`).
  - So README's "latest release" link and INSTALL's "its source code … is at github.com/…" line
    describe the state at the first release. Known, not a finding: no binary has been
    distributed.
- **Built but UNVERIFIED:** the App Translocation guard in `setOn` (refuses On from an
  `/AppTranslocation/` path).
- **Not yet measured:** a plain logout/login (a restart is VERIFIED, `THE MENU AND THE PLAYER ARE
  TIED`); `pmset -g assertions` during playback.
- **A rename in Settings reaches LMS: VERIFIED LIVE on 0.4.5, 2026-10-15** (Simon: "it saves back to
  the server player is now called simonsMac I saved that in the app"). Follow (MAC
  96:57:54:14:bd:87, 0.3.x's player carried on) renamed prodmac46 -> simonsMac in Settings while ON:
  agent.log 00:03:52Z "settings changed: restarting the engine of simonsMac on FiiO M11 Plus";
  `players/follow/name` and settings.json both "simonsMac"; LMS `players` shows "simonsMac"
  (checked over HTTP). So an engine started on a new name file gives LMS that name. On 0.4.5 the
  AGENT wrote the file; in the tree (`THE NAME FILE HAS TWO WRITERS`) the app's Save writes it and
  the same restart follows, so only the writer changed. Still UNVERIFIED: a rename saved while the
  player is off on the TREE, and an LMS rename kept across a later Save.
- **A rename saved while OFF does not reach LMS on 0.4.5: CONFIRMED LIVE 2026-10-15** (Simon: "I just
  edited Dragnfly whilst off then turned it on name in LMS has not changed but it has in the app"),
  as CODE-REVIEW 2026-10-14 #2 said. settings.json "AudioQuest DragonFly Black v1.5" (saved 01:06:22
  local), `players/AppleUSBAudioEngine-AudioQuest-AudioQuest-Dragon-ea39/name` still "prodmac46
  AudioQuest DragonFly Black v1.5" (Oct 12), agent.log 00:06:23Z started its engine with that file, LMS
  (82:6a:8f:3d:06:01) shows the old name. The tree's fix (Save writes the file) is not built. GAP in
  the tree: a mismatch left by 0.4.x is not repaired by the new build (Save writes only a Name typed
  after the window opened, and the window shows settings.json's name), so this DAC needs its name
  typed again, or the window must show the name file's name (proposed to Simon, not decided).
- **Review after 0.2.2 fixes (findings 1, 3 and 4): INSTALLED as 0.2.3** (Simon: "install and test on
  my dacs", version up yes, 2026-10-10 10:28Z; agent.log "LyrionPlay 0.2.3 (202610101128)", connected).
  1 and 4 VERIFIED LIVE on 0.2.5, below.
  - **4 MEASURED LIVE, FiiO, 2026-10-11 10:06:41 local** (Simon: "do it"; LMS 27, PCM; the stop came
    from the agent's own path, a log-level change, toggled back to info after: settings JSON-identical):
    `slimproto stop` 41.415 → monitor `output on` 41.485, exclusive taken, `device rate 44100` 41.499 →
    `close output` 41.639, WHILE the monitor was starting the device → `opened FiiO M11 Plus at 44100`
    42.235 → close then stopped it, `exclusive mode released` 42.274 → new engine `init output` 42.343.
    The monitor had passed its `running` check, so its "start nothing" branch did not fire; close's
    wait for `monitor_opening` did: 0.6 s, then a clean stop and release BEFORE the buffer was freed.
    No crash report (DiagnosticReports: 0 squeezelite before and after), no SIGKILL by the agent.
    That later moment was not in the suite: added "close while the monitor starts the device stops it"
    (hook `during_next_start` in the fake AudioDeviceStart); FAILED on the old close ("the device runs
    after close (0 at return, 1 after)"), passes now; engine output 26/26, all suites PASS. Test-only
    change: the installed 0.2.5 engine is the code that was verified.
  - **How to time it, for a rerun:** the agent re-probes devices (`squeezelite -l`) before it stops the
    engine, so the stop signal lands ~0.6 s after the tick and `close output` ~0.8 s after; the tick
    is visible as status.json being rewritten every 2 s. Write the setting before the tick, play AT
    the tick. The play must be from idle (wait for status `exclusive` false): after an engine restart
    LMS restarts the stream on the new engine, so the device is open again until the idle release.
    (5 earlier attempts missed on these two points; the script was a session scratch file, not kept.)
  - **1 MEASURED LIVE, 2026-10-11 09:00 UTC** (Simon: "yes" to the plan). LMS answers in ~30 ms, so the
    race was staged: a stand-in LMS on 127.0.0.1:9000 only (a session scratch script, not kept; stopped
    by its captured PID) held each `players` reply 3 s. Server set to `127.0.0.1` → status adopted it
    (9.4 s). The next check of it ARRIVED at 15.27 s; the server was set back to automatic at 15.29 s;
    the agent's tick saw it at 17.58 s (status serverName None); the held reply landed at 18.28 s,
    AFTER the change: the race. It was dropped: status stayed None, then "Simons Music" at 23.43 s, and
    the stand-in got NO further request in the 22 s that followed (the old code would have readopted
    it at 18.28 s and checked it every ~6 s for good). settings.json identical to before (JSON compare);
    LMS: prodmac46 connected again. No sound; the player was off the real LMS for ~16 s.
  - **3 MEASURED LIVE on the DragonFly, 2026-10-10 11:29-11:32 local** (Simon chose the DACs and LMS
    volume 27; local FLACs: The Roots "!!!!!!!" 44.1k, track 816519; Johanna Warren ":/" 48k, track
    798330; each ~7 s, then 40 s idle so the DAC was released; player checked stopped before each):
    - decoder first, 44.1k → 48k (11:32:02): ONE `device rate 48000`, one `opened … at 48000 Hz`, 0.74 s
      after `output on`. The fix works.
    - monitor first by 72 ms (11:30:28, 44.1k → 48k) and by 10 ms (11:31:15, 48k → 44.1k): opened at the
      last rate, then reopened, as before the fix: +0.73 to +0.77 s.
    - the cost is the DragonFly relocking inside the open after a rate change (~0.73 s; `set_rate`
      itself reports 10 ms); an open with no rate change took 0.13 s (11:29:41).
    - so the decoder is first in about half the plays (2 of 4 here; 4 of 4 in the morning's log).
- **RATE DELAY STRETCHED AT PLAY — FOUND 2026-10-11 in my own TWO RATE SWITCHES fix; FIXED the same day,
  INSTALLED as 0.2.5 (Simon: "build and install it then test", version up yes; 08:54Z) and VERIFIED LIVE**
  (Simon asked what the fix would cause for a listener). Default and Simon's setting are 0 ms (FiiO
  `rateSwitchDelayMs: 0`, the DragonFly unset), so NO effect on the rig as configured.
  - With "Silence on a rate change" N ms (Settings stepper, 0-2000), output.c plays N/2 BEFORE the switch,
    counted as `current_sample_rate * N / 2000` frames, and N/2 after. The fix now opens the device at
    the NEW rate first, so that first half is counted at the old rate but played at the new one: it
    lasts N/2 x old/new. A play from idle after a higher-rate track is stretched: 96k -> 44.1k x2.2,
    192k -> 44.1k x4.4, 384k -> 44.1k x8.7 (N = 2000: ~8.7 s of silence before the music, where 0.2.2
    took ~2.8 s in all). Going up (old < new) it shrinks, and the silence after the real switch stays
    >= N/2, as before. The DSD delay (`dsd_delay`) is the same mechanism but the agent passes `-D`
    with no value, so it is 0.
  - Fix: when `_ca_open` opens at a pending track's rate that differs from `current_sample_rate` and a
    delay will apply (`_start_delay()`, which mirrors output.c: the rate delay on a rate change, the
    DSD delay on a format change), it sets `output.delay_active = true` ("the first half is done: the
    switch happened in the open"). The track start then plays only the second half, N/2 counted at the
    new rate: the old code's silence after the switch, with no stretched first half.
  - `delay_active`'s other users: output.c's track start consumes it (the pending track's, the one
    `_start_delay` was computed for); `output_flush` clears it on a stop or a new stream while the
    device is open. A same-rate open (no switch) never sets it, so a DSD format change at one rate keeps
    both halves.
  - Tests: the fake `_output_frames` now carries output.c's delay rule (output.c:129-150) and counts
    the silence in seconds at the device's rate. "the rate delay is not stretched on a play from idle"
    (96k -> 44.1k, 2000 ms: 1.00 s; FAILED without the fix at 3.18 s) and control "the rate delay at a
    gapless boundary is both halves" (1 s before the switch, 1 s after; passes on both). Engine output
    25/25, full suite PASS.
  - **MEASURED LIVE on the FiiO, 0.2.5, 2026-10-11 09:55-09:56 local** (Simon agreed: the FiiO's
    "Silence on a rate change" set to 2000 ms for the test, engine `-r …:2000`, then put back to 0;
    settings.json byte-for-byte the same as before by JSON compare; LMS 27, PCM only): George Harrison
    "It's Johnny's Birthday" 192k (track 795396) from idle after 44.1k: rate found after 90 ms, one
    switch, then only `pause 192000 frames` (1.0 s at 192k) after "track start", no first half. The
    Roots 44.1k (816519) from idle after 192k: one switch, then only `pause 44100 frames` (1.0 s). 0.2.4
    would have played `pause 192000 frames` at 44.1k first: 4.35 s more.
- **TWO RATE SWITCHES AT PLAY, THE WAIT — DECIDED by Simon 2026-10-10 ("Add the wait"), INSTALLED as
  0.2.4 2026-10-11 08:25Z, MEASURED LIVE (below).** The decoder sleeps up to 100 ms between runs (`decode.c:116`) and the off poll is 100 ms,
  so which sees a play first is timing: the live test showed the monitor first in 2 of 4 plays. My
  first build (0.2.3) opened at once when the rate was not yet known (no added time); Simon chose a
  capped wait instead, with the numbers in front of him: saves ~0.7 s when the rate differs, costs up
  to ~0.1 s when it does not.
  - `monitor`, after its loop, on every path to an open: while the output is `OUTPUT_BUFFER` (a play)
    and `_track_pending()` is false, it looks every `TRACK_WAIT_US` (10 ms) up to `TRACK_WAIT_POLLS`
    (15, so 150 ms), logging "track rate found/not found after N ms". A resume (`'u'`, straight to
    running) does not wait. First placed inside the off branch, where a monitor already on its
    device-available path skipped it (the new test caught it).
  - Tests "a play waits for the decoder and switches the rate once", "a play the decoder is slow for
    opens after 150 ms, as before" (both FAILED with the wait disabled, at 44100 Hz, as live), control
    "a resume does not wait". Suite: engine output 23/23 (four runs), all suites PASS.
  - After close the loop exits on `running` before touching the buffer (`outputbuf` is a static
    struct, `output.c:30`), as the off poll already did.
  - **MEASURED LIVE on the DragonFly, 0.2.4, 2026-10-11 09:26-09:29 local** (same test as 0.2.3: Simon
    chose the DragonFly in Settings, volume 27, alternating 44.1k / 48k from idle): the monitor saw the
    play first in ALL 4; it waited 10, 50, 10, 50 ms, logged "track rate found", and each play had ONE
    `device rate` and ONE `opened` line. `output on` to open: 0.76, 0.83, 0.78, 0.80 s.
  - **CORRECTION to the saving quoted to Simon ("~0.7 s when the rate differs"):** it holds only when
    the DAC is at NEITHER the last track's rate nor the new one: the first play after the engine starts
    (`current_sample_rate` is the 44.1k default, the DAC wherever macOS or another app left it: the
    morning log's FiiO and DragonFly plays were both right after an engine restart), or after another
    app changed the DAC's rate while it was released. Then the old code relocked twice (+0.73 s; if
    the DAC was already at the track's rate, +~1.4 s against none). In steady state the DAC sits at the
    last track's rate, so the old code's first open was cheap (0.08 s, no relock) and its reopen the
    one relock: 0.2.3's monitor-first plays took 0.86 s from `output on` to the reopen, against 0.80-0.83
    s here. So steady state gains ~0.03-0.06 s, and a same-rate play the monitor sees first pays the
    wait (10-50 ms measured, 150 ms cap) with nothing to gain. Told Simon; his call whether the wait stays.
  - **MEASURED LIVE on the FiiO M11 Plus, 0.2.4, 2026-10-11 09:34-09:37 local** (Simon: "fiio is ready";
    engine restarted for it at 08:34Z, so `current_sample_rate` was the 44.1k default and the FiiO sat at
    48k; LMS 27 as software gain, the FiiO has no Mac volume control): 48k FIRST, the after-restart case:
    NO rate change at all, opened at 48000 Hz 0.10 s after `output on` (0.2.2/0.2.3 would have relocked to
    44.1k and back, as the 09:53:07 FiiO play on 2026-10-10 did: 1.49 s). Then 44.1k, 48k, 44.1k: ONE
    `device rate` and ONE `opened` each, 0.76, 0.77, 0.77 s. The monitor was first in all 4 (waits 20,
    20, 30, 30 ms); 8 of 8 across both DACs on 0.2.4.
  - **DSD MEASURED LIVE on the FiiO, 0.2.4, 2026-10-11 09:45-09:48 local** (Simon: "test for DSD"; FiiO knob
    turned down first, since DoP plays at full scale and ignores LMS volume): DSD64 "Factory Girl"
    (track 827020) from idle after 44.1k: "DSD64 stream, format: DOP, rate: 176400Hz", track rate found
    after 70 ms, ONE `device rate 176400`, one open; Simon: the FiiO "showed dsd" (DoP lock VERIFIED). DSD256 Carmina Burana "Dulcissime" (827002): "DSD
    sample rate too high for device - converting to PCM", "resampling from 1411200 -> 352800", found
    after 30 ms, ONE `device rate 352800`, one open: the pending rate is the resampler's output, as it
    must be.
- **`REVIEW 2026-10-10` fixes: INSTALLED as 0.2.1 (2026-10-10), plus the `REVIEW OF THE FIXES` fixes in 0.2.2; not yet live-tested.** Proven by the suite against fakes, plus the HAL probes in §A3. Still to see on
  the real thing, each needing Simon (sound, or his settings):
  - "Follow the macOS output" with the FiiO as the macOS output and exclusive on: the first track
    stays on the FiiO (agent.log "staying on it until it lets go"), and choosing the speakers
    while it plays moves the player only after the idle release;
  - a server typed as a qualified name reaching LMS from the real agent;
  - a menu-only `install.sh` update leaving the NEW menu running;
  - a DAC held by Audirvana/Roon: engine.log says why on tries 1-3, then every 5 minutes; play
    starts within 5 s of the other app letting go;
  - resume after a pause longer than 30 s on a `-V` device (the DragonFly): the level is LMS's;
  - Mac volume keys before the first track on a fixed-volume player: agent.log "not sent".

- **DSD RATE IN THE MENU — BUILT 2026-10-11, INSTALLED as 0.2.11, VERIFIED LIVE by Simon 2026-10-11** (Simon: "in LyrionPlayer
  when playing DSD the helper app shows the PCM rate when its DoP this should show the DSD Rate not its
  DoP rate"). The menu's output line was CoreAudio's nominal rate plus physical format, so DSD64 read
  "176.4 kHz · 32-bit integer": the device really runs there, and CoreAudio cannot tell DoP from PCM
  (`NO DOP PROPERTY IN COREAUDIO`). Now "FiiO M11 Plus · DSD64 (2.8 MHz) · DoP · exclusive" [since `CODE-REVIEW 2026-10-12 (4)`
  finding 3: "DSD64 (2.8224 MHz)", the rate in full].
  - **Engine:** `ca_report_format()` prints `lyrionplay:format <rate> <pcm|dop>` once per change of
    the IOProc's own record of the last track start it took (`ca.track_rate`/`ca.track_fmt`), so a
    gapless next track the decoder is already on is not said early. Called by the slimproto thread
    after `UNLOCK_O` (~100 ms; never from the real-time IOProc; printf can block on the pipe). One
    line added to `slimproto.c` (UPSTREAM.md). Engine-only, read-only: it changes no frame.
  - **Agent:** `FormatReport` parses the line; the agent keeps it per engine (`engineFormat`, cleared
    when the engine stops or exits, and a line from a replaced engine is dropped) and writes
    `status.dsdRate` = 16 x the device rate ONLY while the device is at the reported DoP rate. That
    rule alone did NOT cover the idle release: a DAC keeps its rate when we let go, so the menu said
    "DSD64 · DoP" there, and over another app's PCM at 176.4k. Since `CODE-REVIEW 2026-10-12` finding 3
    the engine also says `lyrionplay:format idle` once when the device closes (`ca.dev` unknown), and
    the agent drops the report (`FormatLine`). DSD256 on the FiiO is
    352.8k PCM and still shows as kHz (`DSD256 IS PCM ON THE FIIO`).
  - **Tests:** engine "what plays is reported once per change" (nothing before a track; DSD64, 44.1k,
    352.8k PCM, DSD128 at that same rate; a repeat says nothing; a gapless DSD64 -> 44.1k says 44.1k only
    after the boundary). Mutants: no dedupe FAILS; the decoder's `next_sample_rate`/`next_fmt` FAILS
    (first version of the test, without the gapless half, PASSED that mutant: the half was added for
    it). Swift suite `FormatReports` (parse, DoP rule, a moved device, labels, an old status.json
    without the field). `scripts/test.sh` PASS (engine output 42/42 with the matrix; swift 61 in 16
    suites; install.sh 3/3); engine and Swift products build, no new warning.
  - **Other rates (Simon asked, 2026-10-11):** nothing is rate-specific. DoP is chosen when DSD rate / 16
    <= the device's top rate (`dsd.c`), from `device_rates` over `TEST_RATES` (to 1,536,000); `-Z`'s 384k
    cap is only the HELO's `MaxSampleRate`, and DSD passes through LMS at any rate (`DSD IS PASSTHROUGH AT
    ANY RATE`). So DSD128 = 352.8k on the FiiO (played live as DoP 2026-10-11); DSD256/DSD512 show as DSD
    on a DAC offering 705.6k/1411.2k (Swift cases added; no such DAC here, unverified live).
  - **INSTALLED as 0.2.11, 2026-10-11 22:03Z** (Simon: "build and install", "Yes, 0.2.11" to version up;
    0.2.10 -> 0.2.11 with `bump-version.sh patch`; with it, rounds (4) and (5), never installed before).
    Nothing was playing; the FiiO had left USB at 22:00:46Z ("is not present", agent.log), so the engine
    waits for it. `build.sh --install` suite PASS inside it; install.sh "version 0.2.11 (was 0.2.10)";
    agent.log "agent started: LyrionPlay 0.2.11 (202610112301)", then "LMS: using Simons Music
    (192.168.1.234:9000)"; menu app restarted.
  - **VERIFIED LIVE, 2026-10-11, after the 0.2.11 install** (Simon, on his own: "it works correctly"). Simon ran
    the play himself; which tracks he played was not reported. DSD256/DSD512 as DoP stay unverified (no
    DAC here offers 705.6k).
  - **What the live check was to show:** DSD64 on the FiiO with DoP on shows "DSD64 (2.8 MHz) · DoP"; 44.1k after it
    shows "44.1 kHz"; DSD256 shows "352.8 kHz". Reads the menu only (no tap needed); a play test, so
    ask the player first.

### C. CLOSED FINDINGS

Each entry records that a defect, as described, was fixed. It does not cover the code written to
fix it (see HOW TO LOG).

- **CODE-REVIEW 2026-10-15 (2) — /code-review of the CODE-REVIEW 2026-10-15 fixes (uncommitted tree),
  ALL 7 VERIFIED + FIXED, not built** (Simon: "lets do another /code-review of lyrionPLay", then "The
  saving settings issuesis becoming boring review this area thorouhgly as it feels like same mistakes
  keep happening. Saving settins should not be so complicated. Verify and fix all"). The cause of the
  repeats: the agent applied settings.json's names to the name file and guessed which were typed;
  replaced by `THE NAME FILE HAS TWO WRITERS` (§A2).
  1. **A missing settings.json renamed players over LMS's renames** — VERIFIED in the code:
     `loadSettings` gave `Settings()` for `.missing`/`.older` and both callers set `settingsRead`, so
     `applyName(saved: true)` wrote the defaults' name over a file whose record differed. Writer: a
     player renamed in Settings on this tree (only these have a record), then settings.json deleted
     by hand while `players/` stays. FIXED by the rule: the agent writes no name over a file, so
     `applyName`, `settings-name`, `saved:`, `settingsRead` and `loadSettings` are gone.
  2. **The app's Save over an unreadable file wrote the defaults, and the agent then renamed
     Follow** — VERIFIED: `Settings.load()` gave the defaults, Save wrote them, the agent read them
     with `settingsRead` true. The overwrite was the "not covered" line of CODE-REVIEW 2026-10-14 #1;
     the rename it led to was new. FIXED: the rename by the rule (the window's names are compared
     with what it opened on, so untouched defaults are no rename); the file: `Settings.save` keeps a
     file that does not decode as settings-unreadable.json before writing; the window says so
     (`PlayerModel.settingsUnreadable`, `reload`). Test `anUnreadableFileIsKeptWhenSavedOver`.
  3. **Names past squeezelite's limit, or blank** — VERIFIED in `slimproto.c`: `fgets(player_name,
     PLAYER_NAME_LEN, fp)` with `PLAYER_NAME_LEN` 64 keeps 63 bytes, cut mid-character if need be;
     the defaults' "<Mac> <device>" can pass it; a blank Name wrote an empty file. FIXED:
     `PlayerSettings.fitName` (`nameBytes` 63, whole characters, one line, trimmed) in both defaults
     and at Save; a blank typed Name refuses the Save ("… needs a name."). Test `aNameFitsTheEngine`.
  4. **The engine's `<lms>` -1 comment** said LMS sends an audg only at a track start — VERIFIED
     against §A3 `LMS SENDS VOLUME ON CONNECT`. FIXED, prose only.
  5. **`applyName`'s `saved:` carried the agent's provenance** — VERIFIED; gone with 1.
  6. **The settings adopt written twice (`run`, `tick`), three decodes at start** — VERIFIED (they had
     drifted: `run` fell back to `Settings()`, `tick` kept the old). FIXED: one `readSettings()`;
     `init` no longer decodes.
  7. **`chooseVolume` parsed the MAC file inline** — VERIFIED. FIXED: `PlayerIdentity.mac(at:)`, which
     `loadOrCreateMAC` uses too.
  - Carrier audit: name file: written by `writeName` (app Save), `createNameFile` (agent, missing
    only), `adoptOldPlayer` (copy, missing only), squeezelite (LMS rename); read by squeezelite and
    `renameReached`. settings.json: written by the app's Save, the agent's missing-file save and
    `setAsideOlder` (all through `save`); read by `Settings.read` only (`load` is the tests'). No
    `settings-name` exists on any install (the record was never built).
  - Tests: `aRenameInSettingsReachesTheNameFile` and `theDefaultsNeverRenameAPlayer` replaced by
    `onlyANameTypedInSettingsWritesTheNameFile` (a rename while off, an LMS rename kept, a missing
    settings.json, a device switched on under its default name); `aNameFitsTheEngine`;
    `anUnreadableFileIsKeptWhenSavedOver`. MUTANTS (scratchpad, one copy each): `renameReached`
    always true, `createNameFile` writing over, `renames` without the device, `fitName` cutting past
    63 (survived the first test, killed after a straddling case was added), defaults not fitted,
    `save` keeping nothing: all 6 fail. After: `scripts/test.sh` PASS (engine conversion; engine
    output 69/69; swift 103 in 21 suites; install.sh 3/3); `swift build` of every target, the one
    known warning. Not covered by a suite: the app's Save (UI). Not built, not installed, not
    live-tested. The last step (an engine started on a new name file renames the player in LMS)
    VERIFIED LIVE on 0.4.5 the same day (§B); the tree's own writer (the app's Save) is not.

- **CODE-REVIEW 2026-10-15 — /code-review of the CODE-REVIEW 2026-10-14 fixes (uncommitted tree), FIXED,
  not built** (Simon: "lets do another /code-review lyrionPlay", then "verify them all and look to fix
  check for all carriees and callers that might be affected"). Five findings, all about code the
  2026-10-14 fixes added (a hit on `applyName`/`Settings.read` in that round is not a suppression).
  1. **An unreadable settings.json at agent start renamed Follow in LMS** — VERIFIED: `run` set
     `settings = loadSettings() ?? Settings()`, so Follow ran `followDefaults` (the Mac's name), and
     `makeSlot` -> `applyName(macName)` differed from `settings-name`: it wrote the name file and the
     record, so an LMS rename was lost for good and LMS showed the Mac's name; `tick` did the same at
     any later mtime change while the file still did not read. Writer: a Follow renamed away from the
     Mac's name (any user who renamed it) with a file that does not decode at the agent's start (a
     rollback over a later build's file, a hand edit). Not on this rig today: every player has its
     default name and no record (0.4.5 has none). FIXED: `applyName(_:at:applied:saved:)`; `saved`
     false (the agent's `settingsRead`, set only by a file that read) never writes over an existing
     file and never writes a record over one, and a missing file is made with both, so Settings' name
     replaces it later. Both callers (`makeSlot`, `tick`) pass it; the agent sends no name to LMS any
     other way (only `-N`). Test `theDefaultsNeverRenameAPlayer`; MUTANTS: `saved` ignored (5
     expectations fail), a record written under the defaults (3 fail).
     Unchanged, the 2026-10-14 behaviour while on the defaults: the menu shows Follow under the Mac's
     name (`slot.name`) while LMS keeps the file's; device players are off; `syncFixedVolume` sets LMS's
     fixed pref from the defaults' Follow mode (never Fixed, so never louder) and puts it back at the
     first check once the file reads.
  2. **A file above version 2 was saved back marked that version** — VERIFIED: `read` gives `.current`
     above 2 with its `version`, the app's `draft` came from `Settings.load()`, and `save` encoded it as
     read, with only this build's keys: the later build would skip its migration from this one.
     Writer: a rollback, then any Save. FIXED: `save` writes `currentVersion` (a copy, so every caller:
     the app's `PlayerModel.save`, the agent's missing-file save, `setAsideOlder`, the tests). The app
     reads no `version` and compares no settings, so the number kept in memory is never used. Test
     `aLaterVersionIsSavedAsThisOne`; MUTANT: no stamp fails it.
     - **Found in the carrier audit of `version`:** `read` set aside any file below `currentVersion`,
       not below 2 as §A2 says. Today the same; in the build that raises `currentVersion` to 3, every
       0.4.x file would have been set aside and reset, the case `SETTINGS CARRY OVER FROM 0.4.0 ON`
       forbids. FIXED: `firstPlayersVersion` (2). Test `everyFileFromVersionTwoOnIsRead` (versions 0 to
       `currentVersion + 1`); it cannot fail today, by design: MUTANT (the old rule with `currentVersion`
       3) fails it; control (the new rule with 3) passes.
  3. **`applyName` throws after replacing the name file if the record write fails** — CLEARED,
     MEASURED (scratch probe, the record made immutable so only the second write fails): it threw with
     the file "New" and the record "Old"; the next call wrote both and returned true (a running engine
     restarts). No writer fails the second write and not the first (both in `players/<slug>/`, back to
     back). The order is the one that repairs itself (record first would lose the rename); now said in
     `applyName`'s comment. A directory at the record's path reads as no record and fails before the
     file is written: a hand-made case.
  4. **The comment "0.3.x's keys are all unknown here" was false** — VERIFIED against Simon's real
     settings-0.3.json (0.3.14): `server`, `idleSeconds`, `resampleQuality`, `logLevel`, same types.
     FIXED: the comment names them and what a type change would do; the test's 0.3.x file is now
     0.3.14's shape. ANTI-RUN: a real type change of a shared key (`server` written and read as an
     object) PASSED `aFileFromBeforePlayersIsSetAside` with the old sample and FAILS it with the new.
  5. **`reconcile` passes a switched-off slot to `stopEngines` twice** — CLEARED: `EnginePlan` plans
     only players that are on, so one with an engine is in `changes.stop` and the switched-off loop;
     `stopEngines` nils `slot.engine` in the first pass, so the second does nothing. The second append
     is NEEDED for a slot waiting to restart (no engine, not in `changes.stop`): `stopEngines` cancels
     its `restartWork`. Removing it, the review's simplification, would leave that restart pending.
     Comment added, no code change.
  - After: `scripts/test.sh` PASS (engine conversion; engine output 69/69; swift 102 in 21 suites;
    install.sh 3/3); `swift build` of every target, the one known warning. Mutants in the scratchpad,
    one copy each. Not built, not installed, not live-tested.

- **CODE-REVIEW 2026-10-14 — /code-review of 0.2.10-0.4.5, FIXED, not built** (Simon: "lets do a
  /code-review of lyrionPlay"; on finding 1 "I dont care about migrating older ones to this new build"
  but "if we are moving up version from now then we need to ensure that does keep settings"; then
  "Verify the rest and look to fix"). Scope `origin/dev` 7faf2f8..682cab2 (0.4.5), tree clean; the code
  new since the 2026-10-12 rounds is 15fa252..682cab2. Eight findings, each verified before a fix:
  1. **A settings file that did not decode was set aside as 0.3.x's** (`Settings.read`,
     `setAsideOlder`): any decode failure, or a version other than 2, gave `.older`, so the agent moved
     the file over settings-0.3.json and wrote the defaults. The 0.3.x part is BY DESIGN (index row,
     `ONE PLAYER PER DAC`; the review missed it at Gate 3). The live part is FORWARD: every
     `PlayerSettings` field but `heldVolume` was required, so a later build adding one would have read
     every 0.4.x file as `.older` and reset it. FIXED: `PlayerSettings.init(from:)` requires only
     `name`; `read` gives `.older` only below version 2, reads a version above 2, and gives
     `.unreadable(why)` for a file that does not decode: never moved or written over by the agent,
     which logs "settings.json cannot be read, left as it is" and keeps the settings it had (at its
     start, the defaults). The rule is §A2 `SETTINGS CARRY OVER FROM 0.4.0 ON`. Tests
     `anEarlierVersionTwoFileStillLoads`, `anUnreadableFileIsLeftAlone`. Not covered: the app's
     `Settings.load()` shows the defaults for an unreadable file, and a Save there writes over it.
  2. **A rename saved while the player, or LyrionPlay, was off never reached LMS** — VERIFIED in the
     code: `tick` rewrote the name file only for players in `slots` (those on), and `makeSlot`'s
     `ensureNameFile` wrote only a missing file. Writer: the cog's Name field with the player's switch
     off, or with LyrionPlay off (the Settings window saves either way). Writing the Settings name
     whenever it differs from the file would undo a rename made in LMS (squeezelite writes LMS's
     renames to the file). FIXED: `PlayerIdentity.applyName` with `players/<slug>/settings-name`, the
     name Settings last put in the file: the file is written when there is none, or when Settings'
     name differs from the record; a player from 0.4.0-0.4.5 (no record) keeps its file and gets a
     record. `makeSlot` logs "<name>: renamed in Settings since it last ran"; `tick` restarts a running
     engine only when `applyName` wrote over its file. Checked on this Mac first: all four name files
     equal settings.json's names, so the first start with the record moves nothing. Test
     `aRenameInSettingsReachesTheNameFile` (an LMS rename kept; a player from before the record).
     `ensureNameFile` removed (no other caller).
  3. **Follow switched off while deferred: a reconcile every 2 s** — VERIFIED: `follow.resolve` ran
     only while Follow was on, so `deferred` stayed set and `shouldReconcile(holding: nil)` held at
     every tick (each reconcile runs `squeezelite -l`). FIXED in PlayerCore, still with no reset API
     (`REVIEW OF THE FIXES`, finding 3): `resolve` clears `deferred` and returns nil while Follow is
     off, and `reconcile` calls it every time. Test `switchedOffEndsTheWait`.
  4. **Choosing Fixed moved the DAC by up to 0.5 dB** — VERIFIED: `HeldVolume.dB` was `LMSVolume.dB`,
     the curve before LMS's `dBToFixed` rounding, while *Device's own volume* puts the rounded gain on
     the device. Already in the record: 0.4.0 live, "device volume held at -25.6 dB (was -25.9 dB)" at
     LMS 48 (`PLAYERS AND FIXED BUILT 2026-10-12`); the DragonFly reported LMS 17 at -48.83 dB, not the
     test's -48.84. Largest gap 0.50 dB, at LMS 40 (-29.60 vs -30.10). FIXED: `LMSVolume.gain` (the
     engine's `lms_gain`, the same arithmetic) and `LMSVolume.dB(gain:)`; `HeldVolume.dB` is the level
     of LMS's gain. A held DragonFly's `-a` changes once (-25.65 -> -25.89 at 48), so its engine
     restarts once. Tests `fixedHoldsWhereTheDevicesOwnVolumeHadIt`, `lmsGainsMatchTheEngine` (the
     engine suite's LMS_VOL33-42 gains), the `-a` test now -48.83. Residual: after a Mac-key move the
     device sits at the Mac's exact level (`THE DEVICE STAYS WHERE THE MAC PUT IT`), which a whole LMS
     volume's level can differ from by LMS's rounding.
  5. **`PlayerSettings.macName` stalls the Settings window** — CLEARED, measured (§A3 `THE MAC'S NAME
     LOOKUP STALLS`). No change.
  6. **`stopEngine` stopped engines one at a time on the main queue** — VERIFIED (SIGTERM, then up to
     3 s each; ~0.2 s each to `close output`, CODE-REVIEW 2026-10-12 (7)). FIXED: `stopEngines` signals
     every engine, then waits once, 3 s for all; `reconcile` (still stopping before any start) and
     `shutdown` use it. No suite runs the agent; `swift build` of every target is clean.
  7. **`playerStates` asks `status` per player in turn, so a volume push waits** — CLEARED (§A3
     `A STATUS CHECK HOLDS UP A PUSH`). No change.
  8. **The tap procedure named 0.3.x's one `engine.pid`** — FIXED: each player's
     `players/<slug>/engine.pid`, read BEFORE the bootout (the agent deletes it as it stops an engine),
     and the "engine N of <name> started:" line of the player under test.
  - After: `scripts/test.sh` PASS (engine conversion; engine output 69/69; swift 99 in 21 suites;
    install.sh 3/3). MUTANTS in a scratch copy, one per fix (the old `read`, the strict decode, no
    off-guard in `resolve`, the curve in `HeldVolume.dB`, a name file never rewritten): each FAILS its
    test(s). Not built, not installed, not live-tested.

- **INLINE REVIEW 2026-10-14 — of 0.4.0-0.4.2, FIXED, INSTALLED as 0.4.3, not live-tested** (Simon: "lets do an
  inline review of lyrionplay"). Scope `origin/dev` 7faf2f8..b6b929f, tree clean; rounds 2026-10-12
  (1)-(7) had covered up to 15fa252, so the new code was 15fa252..b6b929f (engine, agent, PlayerCore,
  app, INSTALL.md). Two findings:
  1. **Save turned *Follow the macOS output*'s "Device's own volume" into Software** — VERIFIED with
     PlayerCore built in a scratch package, the save loop verbatim, the suite's FiiO fixture as the
     macOS output: saved `device` was written `software`; back on the speakers Follow read software and
     its engine had no `-V` (the Mac's slider no longer reached LMS); unsaved control: `device`, `-V`.
     Cause: `PlayerModel.save`, a player's switch and the cog's fields wrote `Settings.player(_:device:)`,
     the choice corrected for the device of the moment. Right for a device's own player (`ONLY WHAT A
     DEVICE OFFERS`, its device never changes); since 0.4.0 Follow is ONE record across every output it
     follows. Writer: any output with no Mac volume control as the macOS output, its own player off
     (the FiiO, HDMI). FIXED (Simon: "yes fix that"): `Settings.forSaving(_:device:)` is what the window
     writes (Follow's volume as saved; a device's own player corrected as before), `player(_:device:)`
     still reads every choice as offered; `chooseVolume` unchanged (it sets the user's pick). Test
     `followKeepsItsVolumeChoiceWhateverItFollows`; MUTANTS: the old rule FAILS it (4 expectations, `-V`
     among them), no correction for a device's own player FAILS its control. A Follow record already
     saved as Software by this cannot be told from a choice: not migrated.
  2. **The Fixed caption's "turn it down before saving"** — since 0.4.0 Fixed on a DAC whose volume
     the Mac sets restarts its engine (`-a 0:1` -> `0:1:1:<dB>`) and the hold overwrites the DAC's level
     (live: "held at -25.6 dB (was -64.0 dB, muted)"), so turning it down first changed nothing. Shown
     only when the SAVED mode is Software and Fixed is picked before saving (Simon could not find it
     until the DragonFly was saved as Software; a screenshot settled it). FIXED to Simon's wording:
     "just remove the turn it down bit all is correct up to that": the caption ends "From software
     volume this is louder."; INSTALL.md "Coming from *Software*, this is louder." (also for a DAC
     with no Mac volume, whose caption already says to set the volume on the DAC or amplifier).
  - Dropped at the gates: a Mac move within 500 ms of an LMS level not reported (a residual stated to
    Simon, `THE DEVICE STAYS WHERE THE MAC PUT IT`); Follow's DoP/exclusive carried across the outputs
    it follows (Simon's per-player settings, `ONE PLAYER PER DAC`); a held level put back at every
    engine start (`FIXED HOLDS THE LMS VOLUME`).
  - Read and cleared: `put_lms_level`'s echo/same/restore/first rules, `lv.lock` order, `_ca_open`'s
    hold, `EnginePlan` stopping before starting, the orphan sweep, per-player `LatestValueSender`s.
  - After: `scripts/test.sh` PASS (engine output 69/69, swift 93 in 21 suites, install.sh 3/3);
    `swift build` of every target, the one warning the known `SendableClosureCaptures`. No suite covers
    the app's UI: the three call sites are pinned only through `forSaving`. Simon's DragonFly was left
    saved as Software by the caption check (settings.json 21:54:15).

- **A MAC MOVE UNMUTES LMS AT ITS LEVEL — 2026-10-14, BUILT, INSTALLED as 0.4.2 the same day, VERIFIED
  LIVE by Simon** ("all works") (Simon: "2nd one does happen, so we need to fix that and it should
  unmute LMS and move it the correct position"). The defect: with LMS muted (Material, or a Mac mute),
  moving the Mac's volume made the agent send `mixer muting 0`, so LMS faded back to the volume it kept
  and the device left the level the user had just set.
  - **Why it was so:** that rule was for the Mac's unmute KEY (`UNMUTE IS NOT A LEVEL`): LMS's mute
    leaves the device at its minimum, so the unmute key's report carries the minimum (-63.5 dB -> LMS
    7). Only the engine can tell the key from a move: after LMS's mute its record is the minimum,
    muted, so the key changes only the mute, a move changes the level.
  - **Fix:** the engine's report gains `<moved>` (`lyrionplay:volume <dB> <muted> <lms> <moved>`: 1 the
    level moved past `VOLUME_MOVED_DB`, 0 only the mute changed). The agent (`VolumeReport.levelMoved`,
    `VolumePush`) sends `mixer muting 0` only for an unmute alone with LMS muted; a moved level goes as
    `mixer volume N`, which unmutes LMS at N (`mixerCommand`: "if the player is muted and the volume
    changed, unmute first"; MEASURED on the stand-in 2026-10-14: muted at -42, `mixer volume 30` gave
    volume 30, muting 0, one twin audg 1230; `mixer muting 0` gave a fade up to 30). A moved report also
    no longer asks `mixer volume ?` (one request fewer). The answer to that `mixer volume N` is LMS's
    answer to the report, so `THE DEVICE STAYS WHERE THE MAC PUT IT` leaves the device where the user
    put it. A line without `<moved>` reads as moved.
  - **Carriers:** the only reader of the line is the agent's `VolumeReport(line:)` -> `deviceVolumeChanged`
    -> `LatestValueSender` -> `VolumePush` (unchanged otherwise; the sender keeps the latest report, so a
    key and a move in flight together send the move). `FormatReport`/`FormatLine` still refuse the line.
    Mute reports (`mixer muting 1`), fixed players before any audg, LMS at volume 0 (not muted): unchanged.
  - **Tests:** engine `an unmute alone is not a moved level` (LMS's mute, then the unmute key: `... 0 0 0`;
    then the slider: `... 0 0 1`; a slider that unmutes and moves at once: one report, moved); the 9
    existing report expectations gain ` 1`. Swift `aLevelMovedWhileLMSIsMutedSetsThatLevel` (new),
    `unmuteWhileLMSIsMutedAsksLMSToUnmute` (now marked an unmute alone), the parse rows for `<moved>`,
    `beforeAnyAudgAFixedPlayerGetsNothing` (a moved level asks no volume question; an unmute alone asks
    both). Anti-run, the old agent rule restored: `aLevelMovedWhileLMSIsMutedSetsThatLevel` and
    `beforeAnyAudgAFixedPlayerGetsNothing` FAIL (source restored after, checked). Mutants: `<moved>`
    always 1, always 0: each FAILS the engine test. `scripts/test.sh` PASS: engine output 69/69 with
    the matrix, swift 92 in 21 suites, install.sh 3/3.
  - **Docs:** INSTALL.md (*Device's own volume*), INSTALL.html regenerated.
  - **Owed, live:** with the player muted in Material, move the macOS slider: LMS unmutes at the Mac's
    level (Material shows it), the device stays where the slider is. The engine log shows ONE report
    for that move. If macOS announces the unmute before the level, the first line would read `... 0 0 0`
    and LMS would start its unmute fade before the level follows: watch for it.

- **THE DEVICE STAYS WHERE THE MAC PUT IT — 2026-10-14, BUILT, INSTALLED as 0.4.2 the same day, VERIFIED
  LIVE by Simon** ("all works but we still have lag to materail from the macs volume. This may be
  unavoidable but function wise it works better"; the remaining lag: §B `MAC SLIDER LAG AND THE BLUETOOTH
  HEADSET`) (Simon: "yes" to the design, §B `PERFECT SYNC: SIMON'S
  REQUIREMENTS`). Replaces `LMS'S ECHO IS NOT PUT ON`. The defects: the slider lag (LMS's answer to a
  report put back on the device mid-drag, the settle window then swallowing moves), and the device
  moved off the Mac's level by LMS's rounding (up to 0.74 dB from -30 to 0 dB, 0.25 dB from -37 to
  -30, 1.75 dB at the bottom) whenever LMS sends its saved level: every connect (`LMS SENDS VOLUME ON
  CONNECT`, so every engine start), every stream start (track and album changes), LMS's second audg,
  the end of a resume fade.
  - **The rules** (`put_lms_level`, called by `apply_latest`, so `set_volume` and `_ca_open`'s pending
    level both go through it; the comment above `ECHO_NS` says them in full):
    1. each unmuted report keeps the gain LMS will answer with (`agent_volume`: the agent's whole
       volume from the level as printed; `lms_gain`: LMS 9.1's arithmetic) and the device's scalars
       (`lv_reported`, in `volume_listener`); a muted report goes to LMS as `mixer muting`, no entry;
    2. an audg EQUAL to a report's gain (within `ECHO_NS`, 5 s) is its answer: nothing is written;
       LMS's level is now that gain (held) and stands for those scalars (the pair); older reports go;
    3. an audg equal to the held level is not written (connects, stream starts, twins, a failed send's
       next track: the device stays where the user put it);
    4. an audg equal to the pair's gain is written as the pair's scalars, unmuted (`restore_pair`): a
       resume ends exactly where the Mac left the device;
    5. the first level for a device (`lv.fresh`: an engine start, or a new device ID, `lv_for`) is
       taken as the device is, unwritten, when the device's own level gives that gain and it is not
       muted;
    6. anything else is written as before (`apply_volume`), held, and clears the reports.
    Gains are compared exactly: a different LMS volume is a different gain, except 41/42, 44/45, 47/48,
    which LMS itself sends alike to every squeezelite.
  - **Every carrier:** `set_volume`'s branches before it are unchanged (Fixed `ca.fixed`; Software and
    no volume control, `!hw`; LMS's fixed flag; device absent, pending). -X (linear) goes straight to
    `apply_volume` (it never reports). `put_held_level` (Fixed's hold) is separate and unchanged. The
    settle window and `apply_volume` are unchanged for every level written; `restore_pair` records and
    settles the same way. Lock order: `apply_lock`, then `lv.lock` alone and released before any HAL
    call; the listener takes `vrec.lock` briefly, then `lv.lock` alone. The agent, PlayerCore and the
    app: unchanged (one Swift test added). The audio path: none (the matrix passes). The Melomania's
    stuck dB property: the pair is its channel scalars (elements 1, 2), and the first-level check reads
    its level through `read_device_db`.
  - **Residuals, stated to Simon:** a Mac move within 500 ms of a level LMS put on is still not
    reported (the settle window: LMS's number lags until the next move; nothing heard changes); a level
    changed in LMS while the engine was down is put on at the start (as before); a device back with a
    new ID at another level than macOS kept takes LMS's level at the first stream (as before); a
    future LMS with another volume curve would make answers unrecognised, i.e. 0.4.1's behaviour (the
    engine test pins LMS 9.1's gains as the rig sent them). Not touched, found on the way (§B): LMS's
    fade-out after a Mac mute unmutes the device per step; a Mac level move while LMS is muted sends
    `mixer muting 0`.
  - **Tests** (engine suite; LMS's answers are the gains the rig sent, `LMS_VOL33/40/41/42`, not
    computed): `the engine knows LMS's answer to each report` (17 dB -> volume rows, shared with Swift
    `theAgentsWholeVolumeIsTheEnginesToo`, plus a row only the printed level gives), `LMS's answer to a
    reported level is not put on`, `a track or album change puts nothing on`, `a track change leaves a
    move LMS never got`, `a resume ends where the Mac left the device`, `every other LMS level is put
    on`, `a level put on clears the reports`, `a report never answered is forgotten`, `a pending level
    goes through the same rules`, `an engine start keeps the device where it is`, `an engine start puts
    on a level LMS changed`, `an engine start unmutes a muted device`, `a device back with a new ID
    starts afresh`. **Anti-run** (0.4.1's behaviour: every level written): 7 FAIL (the answer, the
    track change, the failed send, the resume, the pending level, the engine start, every-other via
    the restore). **Mutants**, 15: 14 killed (no answer check; a one-step tolerance; no held check; no
    restore; no first-level check; first level ignoring mute; no clear on a write; no expiry; no reset
    for a new ID; the pair only for the newest report; restore without unmute; no report entry; the
    unprinted level); SURVIVES, equivalent: an answer consuming itself (its twin is caught by the held
    level). The Swift row test FAILS with one row changed (checked, restored). `scripts/test.sh` PASS:
    engine output 68/68 with the matrix (25,690, 0 failed), swift 91 in 21 suites, install.sh 3/3.
  - **Docs:** INSTALL.md (*Device's own volume*: the LMS slider shows the nearest step; the level stays
    through a track or album change, pause and resume, a restart), INSTALL.html regenerated (README.html
    and index.html unchanged).
  - **Owed, live, after an install Simon asks for:** drag the macOS slider on the headset and the
    speakers (Material follows, ends where the slider stops); a track change, an album change, pause
    and resume, a settings change (engine restart): the device's level read before and after
    (read-only HAL), unchanged; Material's slider still moves the device.

- **LMS'S ECHO IS NOT PUT ON — 2026-10-14, BUILT in tree, then REJECTED and REPLACED the same day by
  `THE DEVICE STAYS WHERE THE MAC PUT IT` (its code is gone; never built into the app)** (Simon chose option 1 of three: "yes as long as this doesnt break
  functionality elsewhere"). The defect: §B `MAC SLIDER LAG AND THE BLUETOOTH HEADSET`, the slider lag
  (LMS answers each `mixer volume N` with two audgs; each was put back on the device mid-drag and
  opened the 500 ms settle window, where the user's next moves were recorded as the engine's own and
  never sent).
  - **The rule** (`output_coreaudio.c`, comment above `ECHO_DB`): each level `volume_listener` reports
    is kept with its time (`echo_reported`, before the line is printed, so an echo can only follow
    it; up to `ECHO_KEEP` 16). In `set_volume`, after `find_device` and before `apply_latest`, an audg
    within `ECHO_DB` (1.1 dB) of a level reported in the last `ECHO_NS` (5 s) is an echo
    (`lms_echo`): the device is not touched, no settle window opens, and `volume_pending` is cleared
    (the device is where LMS says). The echo consumes every OLDER report and keeps itself (LMS's second
    audg is an echo too) and the newer ones. An audg that is not an echo clears them all (`lms_echo`'s
    miss), and so does any level put on (`echo_forget` in `apply_latest`, which also covers
    `_ca_open`'s pending level, the one path that does not pass `lms_echo`).
  - **The numbers, from the LMS 9.1 source and the measurement:** `ECHO_DB` is LMS's own rounding: the
    agent picks the nearest slider position (`LMSVolume.volume(forDB:)`: half a step, 0.74 dB below
    volume 25, 0.25 dB above), and `dBToFixed` (Squeezebox2.pm:211) keeps 8 bits from -30 to 0 dB (up
    to 0.52 dB) and 16 bits below (up to 0.3 dB at -74 dB): 1.04 dB at most; measured 0.06-0.46 dB.
    `ECHO_NS` covers the agent's send with LMS answering inside the agent's 4 s request timeout; the
    echo arrived 8 ms after its report (2026-10-14 14:00:41).
  - **Every carrier:**
    - `set_volume`'s other branches are before the check and unchanged: Fixed (`ca.fixed`) returns
      first; Software and a device with no volume control (`!hw`) return first (no listener, so nothing
      is ever recorded); LMS's fixed flag (`output.volume_fixed`) returns first; a device not found
      stays pending, as before.
    - `volume_listener`: the only writer of reports. It reports nothing in -X (linear), under LMS's
      fixed flag, or inside the settle window (unchanged), so none of those can make an echo.
    - `apply_volume` and `VOLUME_SETTLE_NS`: unchanged for every level that IS put on, so the speakers'
      coarse read-back (`READ-BACK IS NOT THE LEVEL SET`) and LMS's fades keep their window.
    - Mute: LMS mutes with gain 0, -inf dB, never within 1.1 dB of a report: always put on (test). A
      Mac mute reports its level and the agent sends `mixer muting 1`; LMS's fade down may start within
      1.1 dB of it, so its first step can be skipped; the next is put on and clears the reports. Unmute:
      the fade up's first steps are put on and clear them, so the last (the level) is put on too.
    - Resume after the idle release (`RESUME IS ONE AUDG`, a fade in every 50 ms): its steps start at
      0 and are put on as before; the last step can only be skipped within 5 s of a report and 1.1 dB
      of it, i.e. at the level the device already has.
    - `apply_lock` / lock order: `echo.lock` is only ever held alone, never across a HAL call.
    - The agent, PlayerCore and the app: unchanged.
    - The audio path: none (`set_volume` is LMS's audg; the 25,690-scenario matrix passes).
  - **REJECTED AS IS by Simon 2026-10-14** ("I cant except a volume change if its heard this is not
    acceptable and would need more thorough investigation on how to acheive a perfect sync"): the
    residual below is HEARD (a Material nudge that changes nothing on the device). Do NOT build or
    install this tree's echo skip; the matching by tolerance is to be replaced after the
    investigation. Found for it, from the LMS 9.1 source: the TWO audgs are `Squeezebox2::volume`
    (called by `mixerCommand`) and the `volume` pref's change hook (Player.pm:75), which calls it
    again; and LMS's own echo mechanism: `mixer volume N seq_no:S` sets the client's sequence number
    (Commands.pm:560), every later audg carries it (Squeezebox2.pm:310, `sequenceNumber` is 0 from
    `SqueezePlay::init` on, so squeezelite always gets the field; the engine ignores it,
    slimproto.h "squence ids - unused"). Not yet measured on the rig.
  - **RESIDUAL (the reason it was rejected):** an LMS level within 1.1 dB of a report less than 5 s old
    that is NOT an echo is skipped too: a nudge of Material's slider by 1 or 2 steps (0.49 dB a step
    above volume 25; below 25 a step is about 1.5 dB, so never) within 5 s of a Mac slider move. The
    device then sits up to 1.1 dB from LMS's level until the next LMS level is put on (the next track
    start re-sends it). Narrowing it (consuming a report after two echoes, a shorter `ECHO_NS`) rests
    on LMS always sending exactly two audgs and on its answer time, neither measured beyond one run.
  - **Tests** (engine suite, all registered): `an echo of a reported level is not put on` (the
    Melomania: a drag reported at -30 and -25, LMS's two echoes of -30 leave it at -25, the next move
    is reported with `<lms>` 1, its own echo is skipped), `LMS's own levels are still put on`
    (speakers: Material's -40, a level near a report older than Material's, a level near a 6 s old
    report, a mute), `an echo consumes the older reports` (a level the drag passed, sent after the
    drag's echoes, is put on), `a level put on at the open clears the reports` (a pending level put on
    by `_ca_open`). **Anti-run** (the tree with the skip disabled, through `OCA_SOURCE`): the first
    three FAIL (the drag pulled back to -30.40 dB; the move after the echo not reported, swallowed by
    the window), as on 0.4.1. **Mutants**, 7 of 7 killed: no skip, no record, tolerance 0, no expiry,
    no consumption of older reports, the hit consumed with the older ones (LMS's second audg then put
    on), no `echo_forget` in `apply_latest` (it SURVIVED the first three tests, so the fourth was
    written for it, and kills it). `scripts/test.sh` PASS: engine output 59/59 with the matrix, swift
    90 in 21 suites, install.sh 3/3.
  - **Docs:** INSTALL.md's "the LMS slider follows a moment later" stays true; nothing else describes
    the old pull-back. This entry, §B, the index.

- **A STUCK DB PROPERTY FIXED — 2026-10-14, INSTALLED as 0.4.1 the same day, VERIFIED LIVE by Simon** ("it works but very laggy in its response": the macOS slider on the headset now reaches Material; the lag is §C `LMS'S ECHO IS NOT PUT ON`)
  (Simon: "okay check over all areas this would hit and be sure to doument thoroughly", after asking
  "couldnt this get confused with a DAC that has no volume control"). The defect: §B `MAC SLIDER LAG
  AND THE BLUETOOTH HEADSET` (the Melomania P100's macOS slider never reached LMS; §A3 `A DB
  PROPERTY CAN BE STUCK`).
  - **The rule** (`read_device_db`, `output_coreaudio.c`): per volume control, the dB property is
    read first, as before. Only when it reads the top of its range (`d >= v->db_max`) while the
    control's scalar is below full (`s < 1.0f`) is it taken as stuck, and the level is the scalar
    through the HAL's ScalarToDecibels (`scalar_to_db`, split out). A working control cannot give that
    pair: at the top of its range it is at full scale. If the conversion fails, the stuck reading is
    kept (as before); a control with no dB property still reads through the conversion (unchanged).
    Cost: one more property read per control per level read (listener calls and records only, never
    the audio path).
  - **Why not the conversion everywhere:** it disagrees with the speakers' dB property mid-range
    (§A3 `SCALAR TO DB IS NOT THE DB PROPERTY`), and their levels were measured against the property.
    On the headset it is exact: writes land at DecibelsToScalar, and ScalarToDecibels gives the dB
    written back (round trip, §B).
  - **A DAC with no volume control** (the FiiO; Simon's question): `find_volume` finds no control
    (`v.n` 0), so `read_device_db` loops over nothing, no listener is added (`init`: `watch_volume` only
    with `dev_has_volume`), and LMS's level is software gain. Nothing to read, nothing to confuse.
  - **Every carrier of the change** (the level is read in `read_device_db` and nowhere else):
    - `record_device_volume`: at init (`watch_volume(dev, &v, true)`), when the listeners move to a
      device (`point_listeners`), after LMS's level is written (`apply_volume`). On the headset the
      record is now the level written, so LMS's own level is not reported back (test).
    - `volume_listener`: the report. Now the headset's real level.
    - `put_held_level`: only the "was" in its log line. Fixed is never offered on Bluetooth
      (`isExternal`), so no writer there today; a USB DAC with a stuck property would log the right
      "was".
    - NOT touched: the writes (`set_control_db`, `apply_volume`: the headset's dB writes measured
      right), `find_volume` and the `-l` list (controls, range, mute; no level), mute (its own
      property), -X linear (the listener returns first), Fixed (no `-V`, nothing watched), the agent
      (it takes the engine's dB: `LMSVolume.volume(forDB:)` puts the headset's -40 dB floor at LMS 23,
      as any short-range device: the DragonFly's -64 dB is about 7; INSTALL.md now says so), the audio
      frames (`read_device_db` is not in the audio path: the matrix's 25,690 scenarios pass).
  - **Tests** (engine suite, fake HAL taught the measured behaviour: `stuck_db`, `chan_volume`
    (elements 1 and 2, no main), `curved_conversion` (another taper than the property, agreeing at the
    ends), and `notify` calling a property's listeners one after another, as macOS announces each
    channel on its own; the 52 earlier tests unchanged and passing):
    - `a stuck dB reading is read through the scalar` (the Melomania as measured: the slider reported
      at -30.00 and -35.00, LMS's -25 not reported back, full read as 0.00): FAILS on the engine
      before the fix (0 reports).
    - `a working dB reading stays the level` (the speakers with a conversion 15.8 dB off mid-range:
      reported -30.00, not -45.83; full 0.00): a control, passes before and after.
    - `a DAC with no volume control is never read or reported` (no listener, software gain, no
      report): a control, passes before and after.
    - Mutants (scratchpad copies through `OCA_SOURCE`): always the conversion, and the conversion
      whenever it disagrees, each FAIL the working-reading test (-45.83); no stuck rule, and a stuck
      rule that keeps the reading, each FAIL the stuck test. SURVIVES: dropping `s < 1.0f`. It is
      equivalent wherever the conversion reaches the top at full, which both devices with one do
      (§A3 lookups: 1.0 -> 0.00 dB); the guard keeps a full-scale reading from ever being replaced.
  - **Docs:** INSTALL.md (*Device's own volume*: Bluetooth headphones that misreport, and a device
    whose quietest setting sits above LMS's bottom), INSTALL.html regenerated; this entry, §A3's two
    rows, §B.
  - **Live:** the headset under Follow, the macOS slider moved, Material followed (Simon, 2026-10-14:
    "it works"). Not separately confirmed: LMS's slider still moving the headset after the fix.

- **PLAYERS AND FIXED BUILT 2026-10-12 — `ONE PLAYER PER DAC` and `FIXED HOLDS THE LMS VOLUME`,
  INSTALLED as 0.4.0 2026-10-12 19:57Z (§A2 version history), NOT live-tested** (Simon approved the plan
  `~/.claude/plans/immutable-purring-hoare.md`). Built in its order, each step's suite passing first:
  - **Engine** (`output_coreaudio.c`, usage line in `main.c`, UPSTREAM.md): `-a <f>:<e>:<x>:<h>`;
    `set_control_db` split out of `apply_volume` unchanged. 7 tests (`Fixed ignores LMS's level`, `a
    held level is put on at the start`, `... never moved by LMS`, `... once per device`, `Fixed without
    a held level leaves the device alone`, `a held level needs Fixed`, `Fixed ignores device volume`):
    5 FAIL on 0.3.14's engine, the 2 controls pass. 7 mutants, 7 killed (no Fixed branch, no gain at
    init, no unmute, a hold at every open, none at init, `-V` not ignored, a hold without Fixed).
    `MATRIX_SIG` 0.3.14 vs tree: 27 of 25,690 differ, all synced starts, each the same on both builds
    in a rerun (`THE MATRIX IS FRAME-EXACT BUT ONE`).
  - **PlayerCore:** `Settings` v2 (`players`, `PlayerSettings`, `followDevice`, `Stored`/`read`,
    `setAsideOlder`), `Players.swift` (`PlayerList`, `EnginePlan`, `HeldVolume`), `Paths` per player
    (`slug`: readable UID cut at 48 + 4 hex of FNV-1a), `PlayerIdentity` per URL, `AgentStatus` v2 +
    `PlayerStatus`, `LMSClient.playerStates(macs:)`, `ServerChoice.playerStates`. Swift 88 tests in
    21 suites, the old ones moved to the new shapes and new ones for every rule in the plan.
  - **Agent:** `PlayerSlot` per player that is on; `reconcile` stops every changed engine before
    starting any; orphans stopped from every `players/*/engine.pid` and 0.3.x's.
  - **App:** Settings = *Players* (row: name, device, switch, gearshape) + *Shared*; the cog opens a
    sheet (`PlayerSettingsView`, state in `PlayerModel.editingPlayer`); the held level read in
    `chooseVolume`; the menu shows one block per player.
  - **Docs:** INSTALL.md (Settings, the cog, Fixed holding, log names) + INSTALL.html regenerated;
    README.md and CHANGELOG wait for the merge to main. The CHANGELOG must say: settings start fresh
    (0.3.x's set aside); the 0.3.x LMS player carries on as *Follow the macOS output* (`THE OLD
    PLAYER CARRIES ON`); each device player switched on is a new LMS player, named "<Mac's name>
    <device's name>".
  - `scripts/test.sh` PASS: engine output 52/52, swift 88 in 21 suites, install.sh 3/3; `swift build`
    of the agent shows one warning, the same one 0.3.14 has (a clean build of HEAD, same line).
  - **LIVE, 0.4.0, 2026-10-12 (Simon: "most appears to work check current volume level of the
    dragonfly"):** Simon set it all up himself: Follow on the speakers, the DragonFly and the FiiO
    players on, both Fixed (FiiO `-a 0:1:1`, no level: no volume control). The DragonFly's Fixed held
    LMS volume 48: `-a 0:1:1:-25.65`, engine log "device volume held at -25.6 dB (was -25.9 dB)" at
    20:13:43Z. At 20:15:11Z, with that player PAUSED in LMS (saved volume 48, `digital_volume_control`
    0), a read-only HAL read of the DragonFly: -25.65 dB, mute off. So the level survives a pause.
    **FIXED SET UP WHILE PAUSED VERIFIED LIVE 20:16:19Z** (Simon: "setting to fixed whilst paused set
    the volume to what was in LMS check this now"): Device's own volume at 20:15:23Z (the agent put
    LMS's faded 0.0 back to 48, `volumeRestore`), played, paused, so the pause fade left the DragonFly
    muted; then Fixed while paused: engine log "device volume held at -25.6 dB (was -64.0 dB, muted)".
    At 20:17:16Z, LMS paused, saved volume 48, `digital_volume_control` 0: HAL read -25.65 dB, mute off.
    **REPLUG VERIFIED LIVE** (Simon: "just unplugged it and back in again still in fixed is volume still
    the same level"): unplugged 20:17:41Z (agent stopped its engine), back on USB only at 20:21:04Z
    (~3 min; the DragonFly is slow to re-enumerate here, as at 18:04-18:06Z); engine restarted with the
    same `-a 0:1:1:-25.65`, "device volume held at -25.6 dB (was -26.0 dB)" (macOS's own restored
    level), HAL read 20:21:06Z -25.65 dB, mute off; LMS connected, stopped, 48, fixed. The FiiO's player
    also stopped at 20:20:40Z ("its device is not present"); not asked about, not investigated.
    NOT yet seen: a slider move in Material.
  - **Live checks owed** (the plan's Verification, each play test asking the player first): a fresh
    start; the DragonFly as its own player with its own volume; Fixed set up while paused holding
    LMS 17 at -48.8 dB, through pause, a Material slider move and a replug; the FiiO bit-exact in Fixed
    with "Volume can be adjusted" set in Material; *Follow the macOS output* staying on the built-in
    output while the DragonFly, its own player on, is the macOS output.
- **CODE-REVIEW 2026-10-12 (7) — /code-review of 0.2.10-0.3.14, CLOSED with no code change** (Simon:
  "lets do another /code-review"; scope `origin/dev` 7faf2f8..15fa252, tree clean). Four findings:
  1+2 CONFIRMED, two fixes built and REVERTED by Simon, requirement moved to `ONE PLAYER PER DAC`
  (§B `FIXED SET UP WHILE PAUSED`); Software's case a known limitation (§A2); 3 DISMISSED (§A2 `SAVE AND
  CLOSE`); 4 not answered. The tree is back at 15fa252 (0.3.14, installed); nothing was built.
  - Cleared on evidence: build.sh:53 compares `wc -l`'s padded count with `-eq`, true under sh, dash,
    bash and zsh (measured; a string `=` would fail).
  - Measured on the way, for the plan: LMS 9.1 `Player::fade_volume` sends an audg every 0.05 s from
    the level it starts at (Player.pm:373-396); under fixed volume (`adjust` 0) the engine passes
    FIXED_ONE whatever the gain (`process_audg`, slimproto.c:450); the agent's `stopEngine` waits up to
    3 s for the engine to exit, and SIGTERM reaches `close output` in ~0.2 s (engine.log).
- **CODE-REVIEW 2026-10-12 (6) — /code-review of 0.2.10-0.3.13** (Simon: "lets do another /code-review
  of lyrionplayer show me the resutls before acting on anything", then "Dimiss 4 I dont care about the
  lag", then "fix those"). Scope `origin/dev` 7faf2f8..tree (no commits past it). Gate drops: the same
  set as round (5). Four findings: 1-3 FIXED, 4 DISMISSED (`THE FORMAT CHANGES WHEN OUTPUT HITS THE
  DAC`, now covering any lag). After: `scripts/test.sh` PASS (engine output 45/45, swift 76 in 17
  suites, install.sh 3/3); `swift build` clean (agent + app); `sh -n scripts/build.sh` clean. No suite
  covers the app's UI, so 1 and 2 are pinned by none. **INSTALLED as 0.3.14** 2026-10-12 15:15Z (Simon:
  "build and update all docs", "Yes, 0.3.14"; §A2 version history), with the docs. Fix 2 VERIFIED LIVE by Simon ("yes I see never now", "correct I see it": stepper and caption); fix 1
  STAGED + VERIFIED LIVE (the switch-on message survives Save and Close; §A2 version history, 0.3.14).
  1. **A good Save wiped a switch-on error** — VERIFIED from the code: `PlayerModel.save` set
     `lastError = nil` on success, so the menu panel lost "Install LyrionPlay with install.sh first…"
     (or a `LaunchAgent.turnOn` error) at the next Save; Revert and the window opening kept it (round (2)
     finding 4). FIXED: a good save calls `clearSaveError()`. Carriers: `lastError` is written only by
     `setOn` and `save`; a switch-on error written after a failed save stays (it no longer equals
     `saveError`).
  2. **At 0 the release stepper said "after 0 s"** — VERIFIED: 0 passes no `-C` (`EngineArguments`), so
     the engine opens the device at start and keeps it (INSTALL.md: "0 keeps it"). FIXED: the stepper
     reads "Release the device: never" at 0, and the Exclusive caption says the device is held "while
     the player is on" then, not "while the player is playing".
  3. **build.sh's comment put the codec-source check "before anything is built"** — VERIFIED: it runs
     after `deps/build-deps.sh` (which fetches the archives on a fresh checkout; round (5) finding 2).
     Prose only: the comment and this file's Layout line now say "straight after the codec build".
  - **Checked and cleared in this round** (not findings; do not re-derive): `status` carrying
    `digital_volume_control` (Material has read it for years); the engine's `-f` redirects stderr only,
    so stdout carries only the `lyrionplay:` lines; `codec_pins` works with macOS awk (`{64}`) and macOS
    `shasum -q`; every changed line in README.html/INSTALL.html/index.html matches its `.md`.

- **CODE-REVIEW 2026-10-12 (5) — /code-review of 0.2.10-0.3.12** (Simon: "lets do a /code-review of
  lyrionplayer show me th results before proceeding", then "fix them all ensure no regressions check all
  carriers for the core audio, the audio side should be done by now yes things keep popping up"). Scope
  `origin/dev` 7faf2f8..tree (no commits past it). Gate drops: a stalled LMS, the format at a reopen, the
  silence format, the `volumeRestore` slider window, `syncFixedVolume`'s four requests, the ignored
  `client.call` result, `ca_report_format`'s second lock, the tracked test binary, and others already in
  the index. ALL 5 VERIFIED + FIXED, plus one of finding 1's class and the flush pin from the carrier
  sweep. After: `scripts/test.sh` PASS (engine output 45/45, swift 76 in 17 suites, install.sh 3/3); the
  6 report tests 20 runs of 20; agent and app build (only the known `SendableClosureCaptures`); every
  engine source and header byte-identical to before (`shasum`), so the engine is unchanged, and of the
  Swift sources only `Agent/main.swift`. **INSTALLED as 0.3.13** 2026-10-12 14:34Z (Simon: "build and
  update", "Yes, 0.3.13"; §A2 version history); no change in behaviour to live-test.
  - **How build.sh was tested:** an APFS clone of the repo (`cp -Rc`, in the session scratchpad), the new
    `build.sh` and a copy of the old one run in it under /bin/sh, each case staged for real; Simon's tree,
    `deps/` and `dist/` untouched.
  1. **`build-deps.sh | tail -15` hid a failed codec build** — VERIFIED: clone with the opusfile archive
     changed and its stamp removed (so `fetch`'s SHA-256 check fails): the OLD script exited 0 and printed
     `built:`, linking the libopusfile.a an earlier build left. FIXED: build-deps.sh's stdout to
     `build/build-deps.log`, its status checked, then the same `tail -15`; not `set -o pipefail` (dash,
     which /bin/sh can be, lacks it). New: "FAIL: deps/build-deps.sh stopped", exit 1, before the engine.
     - **The same class, found in the sweep of every script's pipelines:** `swiftc … | grep -v 'search
       path' || true` for `make-icon` went on with an OLDER make-icon after a failed compile. FIXED (swiftc's
       status; the binary removed so the next build compiles it again). Clone, a source that does not
       compile: old `built:` with the stale tool; new "FAIL: make-icon did not compile", binary removed.
       The other pipelines are display only, or fail safe (install.sh's cdhash read: empty = changed =
       restart; build.sh's `ents`/`libs` are behind checks that fail first).
  2. **`--release` wrote the app zip before the codec-source checks** — VERIFIED: clone with the soxr
     archive changed and its stamp kept: the OLD script built everything, wrote `LyrionPlay-0.3.12.zip`,
     then failed the SHA-256 check, leaving it with no codec-sources zip. FIXED: `codec_pins` and
     `check_codec_sources` run straight after the codec build (`== codec sources`), not "before the
     build" as the review said: on a fresh checkout the archives arrive by build-deps.sh's `fetch`. The
     release step then copies, checks the COPIES again, zips the sources first and the app LAST. New:
     stops at `== codec sources`, before the engine, `dist/` empty. Control, a clean `--release` with each
     script: both zips hold the same files at the same sizes; the codec-sources content identical; its 9
     archives the same as Simon's `deps/src` (cmake-4.4.4.tar.gz, a build tool, not shipped, as before).
  3. **The `!rate` guard in `ca_report_format` was pinned by no test** — VERIFIED: mutant without `!rate
     ||`, the OLD suite 43/43 PASS. Writers of an open device with `ca.track_rate` 0 (it is 0 only from
     init to the IOProc's first track start; never reset): "Release after" 0 (the agent passes no `-C`,
     so the device opens at the engine's start and is kept), and every first play from idle while it
     buffers. Tests "nothing is reported while a kept device waits for a first track" and "… while a first
     play from idle buffers", each with a control that the track start is then said once; both FAIL on the
     mutant with `lyrionplay:format 0 pcm`. The review's "cannot fail" for the first check of "what plays
     is reported once per change" was WRONG: with the device closed it pins that nothing is said at the
     start (mutant without `if (!said_open) return;` fails it); its message now says so. The agent drops a
     rate-0 line anyway (`FormatReport`, test `lyrionplay:format 0 dop` -> nil).
     - **CARRIER SWEEP of the CoreAudio side** (Simon: "check all carriers for the core audio"): the only
       engine code new since the last dev push is `ca_report_format` and its one call (slimproto.c:751).
       Readers/writers: `ca.track_rate`/`ca.track_fmt` written only by the IOProc at a track start (and
       init's memset), read by `_silence_fmt` and the report; `ca.dev` written under the lock by `_ca_open`,
       close and init; `said_*` only by the slimproto thread. A 14-mutant sweep (every condition, every
       assignment, the device rate for the IOProc's record, both `fflush(stdout)`): 12 killed, the two
       flushes SURVIVED. MEASURED that they matter: neither engine nor agent sets stdout's buffering, and
       stdout is a `Pipe`; a line printed unflushed reached the pipe's reader after 3.31 s, the writer's
       whole life, against 0.04 s flushed. So without them the menu's DSD line and the Mac-volume -> LMS
       push would wait for the buffer to fill or the engine to exit. PINNED: the suite's `fake_fflush`
       (the real one is still called) and `CHECK_FLUSHED()` in the two format tests and the volume test
       (`notify` waits for the listener, so no race). Sweep again: 14 of 14 killed. Out of the suite's
       reach: the slimproto.c call itself (slimproto.c is not linked; VERIFIED LIVE since 0.2.11) and its
       place after `UNLOCK_O` (the same mutex as `LOCK`: under it, it would deadlock).
  4. **The layout line said `--release` makes one zip** — FIXED (both zips, the early check).
  5. **`volumeAfter.map { "\($0)" } ?? "?"` could not fall back** — FIXED: `if let restore = …, let
     volumeAfter`, interpolated directly; the log text is the same (Double's description, e.g. "0.0").
     The contract the new form needs (a restore only with both reads) is pinned by
     `aFadedVolumeLMSSavedIsPutBack` (`after: nil` -> nil).

- **CODE-REVIEW 2026-10-12 (4) — /code-review of 0.2.10-0.3.11** (Simon: "lets do another /code-review
  lyrionplayer", then "verify all 5"). Scope `origin/dev` 7faf2f8..tree. Gate drops: `ca_report_format`'s
  second lock, the format at a reopen, a stalled server, the tracked test binary; one candidate cleared on
  the source (`NO STRAY IDLE ON A REOPEN`). The licence work (0.3.8-0.3.11), reviewed for the first time:
  the 15 texts are present and right. All 5 VERIFIED; 1, 3, 4, 5 FIXED (3 first, then Simon: "fix them"), 2 a
  repeat. After: `scripts/test.sh` PASS, and a plain `build.sh` (suite inside it) built `build/LyrionPlay.app`
  with its checks clean and its `licences/` identical to the installed 0.3.11's. **INSTALLED as 0.3.12**
  2026-10-12 13:42Z (Simon: "build and install"), not live-tested (§A2 version history).
  1. **The codec-sources zip copies `deps/src` unchecked** (`build.sh --release`, whose comment says "the
     exact ones deps/build-deps.sh checked by SHA-256") — VERIFIED in a sandbox under /bin/sh (zsh does not
     split `$archives`: a first run under it made one file with newlines in its name): with all 9 libraries
     stamped (`.built-*`) and every archive replaced, build-deps.sh printed "already built" 9 times and
     checked no hash, and the release loop, run verbatim, copied all 9 replacements with no error. Writer:
     only an archive changed by hand after its build (`fetch` downloads only a missing file, and a missing
     one stops the release); none today: all 9 match build-deps.sh's hashes (`shasum -c`, 2026-10-12).
     **FIXED:** the release step reads each archive's SHA-256 from the line after its `fetch` (`pins`, awk),
     stops unless there are 9 fetches and 9 pins, then `shasum -a 256 -c` in `deps/src` before any copy;
     the comment now says why (build-deps.sh skips a library already built). Sandbox, the block run
     verbatim under /bin/sh: all 9 replaced -> stopped, 9 FAILED named, 0 copied; only opus replaced ->
     stopped, opus named; a pin moved off its fetch's next line -> stopped on the count; control, the real
     archives -> 9 + build-deps.sh copied, byte-identical; the OLD block on the replaced set copied all 9.
  2. **`volumeRestore` undoing a slider move between its reads** — a REPEAT: accepted in §A2 (`FIXED AT 100%
     PER DAC`, "Volume put back"), and the code is still that design (read, send, pref read, read, put
     back). The review missed it because the index did not carry it; the `THE DVC HOOK SAVES A FADED VOLUME`
     row now does.
  3. **`DeviceCaps.dsd`: "cut to 0.1 MHz, as DSD rates are named"** — VERIFIED by arithmetic: DSD512
     (22,579,200) reads "22.5 MHz", usually called 22.4; 48k-family DSD64 (3,072,000) reads "3.0 MHz";
     `dsdLabels` pins both. NO WRITER on the rig: the one reader is the menu's DoP line (16 x the device
     rate), and DSD512 as DoP needs a 1,411.2k device (DragonFly and speakers 96k, FiiO 384k). The library's
     DSD (LMS `titles` tags oT, 2026-10-12) is 19 DSD64, 1 DSD128, 25 DSD256 and 7 DSD512 files, all 44.1k
     family. The review's suggested fix (round to 0.1 MHz) is WRONG: it makes DSD256 "11.3 MHz".
     **FIXED 2026-10-12** (Simon: "it doesnt matter if my devices dont cover that high other users will and
     needs to display correctly. My dacs dont do 48k clocks but other dacs do", with the table of both
     families, DSD64 to DSD1024, to 4 places). `DeviceCaps.dsd` now gives the rate in full, `%.4f` of
     rate / 1e6: "DSD64 (2.8224 MHz)", "DSD512 (22.5792 MHz)", "DSD64 (3.0720 MHz)". Exact for every DSD
     rate of either family (64 x 44.1k or 48k x a power of 2, all multiples of 100 Hz). `dsdLabels` pins
     all 10 rates of the table; anti-run: 10 of 10 failed on the old code. One reader (the menu's output
     line, `outputLine`). `scripts/test.sh` PASS (engine output 43/43, swift 76 in 17 suites, install.sh
     3/3); `swift build` complete. NOT built into the app, NOT installed.
  4. **The `fixedVolume` comment and the index row name `sent`** — VERIFIED (main.swift:86, the `FIXED AT
     100% PER DAC` index row). `checked` does run on the main queue and `recordRefusal` on the send's task,
     so only the name is stale. **FIXED:** both now say `recordRefusal` (the index row "was `sent`").
  5. **The soxr licence loop repeats the main loop's check** — VERIFIED (build.sh). A simplification with
     no change in behaviour. **FIXED:** one `licence name source...` function: checks each source, then
     `cat`s them in order (soxr: LICENCE, then COPYING.LGPL); quoted arguments, so a checkout path with
     spaces still works (a space-separated list in the entry, the review's suggestion, would not). Old
     and new blocks run verbatim: the same 15 files, `diff -r` identical, all 644 as `cp` gave; an empty
     soxr LGPL stops it with "missing licence text" and writes no soxr.txt.

- **DOCS PASS 2026-10-12 — every doc against the code of 0.3.7** (Simon: "do a pass on all docs to ensure
  nothings missing or reported incorrecly"). Checked against the code, not the ledger:
  - **VERIFIED, unchanged:** install.sh's 7 steps, certificate (`-days 3650`, ten years), signing ids
    (`com.crystalgipsy.lyrionplay[.exe]`), uninstall.sh's removals and `--remove-certificate`, the idle
    default 30 s, the retry cadence (2/4/5 s: "within about 5 seconds"), every log line INSTALL quotes
    (`device is held exclusively by another process`, `LMS check of … took N s`, `back under 2 s`,
    `did not answer`, `no server found`), the 5 s LMS check, the menu reopening itself (`ensureMenu`).
    `engine/UPSTREAM.md` diffed against the pinned archive (SHA-256 matches): exactly the 4 files it
    lists differ, and every hunk is listed.
  - **WRONG, FIXED:** README's volume row said the keys move the LMS slider in every mode; the volume
    listener runs only with `-V` (`watch_volume`, *Device's own volume*), and LyrionPlay now sets LMS's
    fixed level per DAC. INSTALL's intro bullet the same (now "with *Device's own volume*", Simon's keys
    wording kept). INSTALL's "Exclusive on for USB and Thunderbolt DACs": `isExternal` is usb,
    thunderbolt, firewire, pci, avb (now "external DACs (USB, Thunderbolt and the like)"). README's DSD
    row ("DACs that accept it": DoP is a switch, `DOP IS A SWITCH`). build.sh's header said the zip has
    INSTALL.md only (it ships INSTALL.html too).
  - **MISSING, ADDED:** INSTALL: Name and Server, the Advanced section (release time, 0 keeps it;
    resampling quality, only when the device lacks the rate; log detail), Save / Save and Close /
    Revert, what the menu shows (DSD rate for DoP, the lock). README: the menu's rate line, the engine's
    format report, the agent keeping LMS's fixed setting in step. NOTICES.txt: dsd2pcm (compiled in,
    `SOURCES_DSD`) and the Daphile patch. CORRECTION (same day): I said dsd2pcm's notice was not
    shipped; WRONG, squeezelite's own `engine/LICENSE.txt` (shipped as `squeezelite-LICENSE.txt` since
    the first build) carries it. What was missing was the GPLv3 text that file only refers to. This file: the overview's volume line, the layout's INSTALL.html, the missing 0.3.6 install.
  - **LICENCE TEXTS — BUILT 2026-10-12** (Simon: "yes"): the app shipped NOTICES.txt and squeezelite's
    LICENSE.txt (its GPL notice + dsd2pcm's) only. libFLAC/libogg/libvorbis/Opus/opusfile (BSD-3), ALAC
    and Material Symbols (Apache 2.0), the LMS-Material waveform (MIT) and the GPLv3 itself each ask a
    binary release to carry their text. Now `build.sh` copies 15 into `Contents/Resources/licences/`
    (`squeezelite-LICENSE.txt` moved there as `squeezelite.txt`): the codecs' from `deps/src` (kept by
    build-deps.sh; soxr = its LICENCE + COPYING.LGPL), the rest from the repo, with the GPLv3, Material
    Symbols and LMS-Material texts now kept in `app/Resources/licences/` (fetched from gnu.org and the two
    upstream repos). A missing or empty source stops the build ("missing licence text"). NOTICES.txt,
    README and INSTALL point to the folder. INSTALLED as 0.3.10: 15 files, `codesign --verify --strict` OK.
  - Pages regenerated (`tools/make_readme_html.py`). INSTALLED as 0.3.8 2026-10-12 11:08Z (Simon:
    "rebuild and install").

- **CODE-REVIEW 2026-10-12 (3) — /code-review of 0.2.10-0.3.6** (Simon: "/code-review" of "lyrionplayer",
  then "verify 1 & 2 hold up under real world tests, verfif rest and fix"). Scope: `origin/dev`
  7faf2f8..tree plus the untracked `FormatReport.swift`; no unpushed commits. Gate drops: everything
  in rounds (1) and (2), a stalled server, the format at a reopen, the silence format, the caption
  wording, and the four sequential requests in `syncFixedVolume`. The review cleared one check on a
  wrong reason; it was re-cleared on the right one (`AN ORPHAN DIES AT ITS NEXT REPORT`). After the
  fixes: `scripts/test.sh` PASS (engine conversion; engine output 43/43; swift 76 tests in 17 suites;
  install.sh 3/3), and `swift build` is clean. **INSTALLED as 0.3.7** 2026-10-12 10:53Z (Simon: "build
  and install"), suite PASS inside build.sh; no change in behaviour to live-test.
  1. **A probe while the engine holds the DAC reads "Device's own volume" as Software** (since 0.3.4,
     `options(for:)` decides `-V` from the probed `device.volume`; the hog's default-output
     notification makes the agent reconcile) — DISPROVEN, measured: holding the device and playing to
     it leave its volume control visible to `squeezelite -l` (`A HOG DOES NOT HIDE THE VOLUME
     CONTROL`). No writer; nothing changed.
  2. **`PlayerModel.save` rewrites every listed device's volume choice from one misread** — falls
     with 1, because the misread it needs has no writer. The write stores what every reader already
     reads (`ONLY WHAT A DEVICE OFFERS`). Nothing changed.
  3. **`formats[nformats - 1]` in failure messages** — VERIFIED with a mutant (`ca_report_format`
     returning at once, built through `OCA_SOURCE` in scratch): `what plays is reported once per
     change` and `the idle release is reported` both ended "(crashed)" at the first message with
     nothing captured, and their later checks never ran. FIXED: `last_format()` and `last_report()`
     give "(none)" when nothing was captured. The mute test's message had the same pattern
     (`reports[nreports - 1]`) and is fixed too. Anti-run: the same mutant now prints every FAILED
     line, with "(none)" where nothing was captured, and no crash; the suite still FAILs on it.
  4. **`FixedVolumeSync.sent(…)` returned true on a refusal** — VERIFIED: the agent's `guard … sent(…)
     else { return }` logs a refusal, and the tests already named its result `refused`. FIXED: renamed
     `recordRefusal(device:mode:lmsAfter:)`, and its doc says it records. The review's second half
     (`checked(…)` as a mutating predicate) not taken: it returns the command to send, the same shape
     as `ServerChoice.checked`.
  5. **`VolumeMode.offered(by:)` vs `offered(on:)`** — VERIFIED (the overload). The review also said
     the `.device` comment cites the wrong one; that is WRONG: the comment cites the read of a saved
     choice, which is `offered(on:)`'s job. FIXED: the instance method is now `nearestOffered(on:)`,
     and the ledger rows that named it are updated.

- **CODE-REVIEW 2026-10-12 (2) — /code-review of 0.3.2-0.3.5** (Simon: "lets do another /code-review
  of LyrionPlayer", then "1 and 2 are not issues … Verify the rest and look to fix"). Gate drops: round
  1's findings 7 (second lock), the four sequential requests in `syncFixedVolume`, the sync after a
  settings change waiting a check, the tracked test binary, overlapping sends (`A STALLED SERVER IS NOT A
  FINDING`). After: `scripts/test.sh` PASS (engine 43/43, swift 76, install 3/3), `swift build` clean.
  **INSTALLED as 0.3.6** 2026-10-12 10:13Z (Simon: "build and install"; `bump-version.sh patch`,
  `build.sh --install`, suite inside it; agent.log: agent 0.3.6 started, engine on the DragonFly, LMS
  found). None of 3-5 live-tested.
  1. **The last track's format said at a reopen** — DECLINED by Simon (`THE FORMAT CHANGES WHEN OUTPUT
     HITS THE DAC`).
  2. **The idle-release test cannot see 1** — DECLINED with it.
  3. **`scalesSamples(deviceHasVolume:)`'s `.device` branch dead** — VERIFIED: its one caller
     (`volumeCaption`) reads the mode from `Settings.options(for:)`, which maps `.device` on a device with
     no volume control to `.software` (`ONLY WHAT A DEVICE OFFERS`), and `EngineArguments` reads the same,
     so the engine never gets `-V` there either. The comments were the defect. FIXED: `scalesSamples` is
     a property, `self == .software`; both comments say where the rule lives. Test
     `fixedIsLouderOnlyAfterSoftwareVolume` now pins the real path: `.device` saved on the FiiO (no
     control) reads as software and warns; on the DragonFly it does not.
  4. **Revert left the failed-save message** — VERIFIED from the code: Revert set only `draft`;
     `onAppear` cleared `saveError` but not the same text in `lastError`, so the menu panel kept "Could
     not save the settings". FIXED: `PlayerModel.revert()` and `clearSaveError()` (clears `lastError` only
     when it holds the save's message, so a switch-on error stays), used by Revert and `onAppear`. No
     suite covers the app's UI; not live-tested (a failed save needs the settings file unwritable).
  5. **`lyrionplay:volume` lines from a replaced engine sent to LMS** — VERIFIED from the code: the
     readability handler reads the old engine's pipe until it exits, and only `FormatLine` checked
     `self.engine === process`. No live writer seen (needs a Mac volume change in the restart's window).
     FIXED: the same check on both branches, one comment. Agent main has no suite; compiles.

- **CODE-REVIEW 2026-10-12 — /code-review of 0.2.11-0.3.1** (the DSD rate in the menu, Fixed at 100% per
  DAC, the volume put-back; scope `origin/dev` 7faf2f8..tree, no unpushed commits). Eleven findings. Simon:
  "I have not seen 1 happen in operation this appears to be some theory unproven. Verify all of them before
  recommending fixing. Check fixes work and ensure no regressions all carriers are looked at." After:
  `scripts/test.sh` PASS (engine output 43/43 with the matrix; swift 74 tests in 17 suites; install.sh 3/3);
  agent, app and engine build (the one warning the known `SendableClosureCaptures`). BUILT 2026-10-12
  09:54 local (Simon: "build and test for the changes"): `scripts/build.sh`, suite PASS inside it,
  `build/LyrionPlay.app` 0.3.1 (202610120954), the version NOT raised (not handed over); checks clean
  (arm64, runtime, 0 entitlements, system libraries only); the new strings in all three binaries. NOT
  installed then. **INSTALLED as 0.3.2, 2026-10-12 09:05Z** (Simon: "install", "Yes, 0.3.2"; 0.3.1 ->
  0.3.2 with `bump-version.sh patch`; prodmac46 found PAUSED at volume 18, Simon told the restart would stop
  it). `build.sh --install`, suite PASS inside it (engine output 43/43, swift 74, install.sh 3/3); install.sh
  "version 0.3.2 (was 0.3.1)"; agent.log "agent started: LyrionPlay 0.3.2 (202610121005)", engine on the
  DragonFly with `-V`, "LMS: using Simons Music"; LMS: connected, stopped (the restart), volume 18 kept,
  `digital_volume_control` 1 (= the DragonFly's device mode: nothing sent, correct). NOT live-tested: the
  menu after a DoP play and the idle release (needs the FiiO with DoP: shows kHz, not DSD64, once released),
  and the caption/warning in Settings.
  1. **Fixed caption: "the Mac's volume keys set it"** — first UNVERIFIED (Simon: "this appears to be
     some theory unproven"), then CONFIRMED by Simon: the keys act on the macOS output only, and on the
     rig that is not the DragonFly. The review's own chain (the hog moving the default) is still
     unmeasured on a DAC and was not needed. Wording FIXED (§B, `THE VOLUME KEYS ON A FIXED DAC`).
  2. **The "louder" warning keyed on the device, not the mode left** — VERIFIED from the code: only
     `.device` passes `-V` (`EngineArguments`), so Software -> Fixed starts the same engine (no restart),
     and LMS's audg goes to unity at once (`SETTING DVC SENDS AN AUDG AT ONCE`): louder by LMS's software
     attenuation, with no warning on a device that has a volume control. Writer: the Settings picker
     (Software is offered for every device); none of Simon's devices is in Software with a volume control
     today. FIX: `VolumeMode.scalesSamples(deviceHasVolume:)`, read against the SAVED mode
     (`volumeCaption`); the window reloads the saved settings when it opens (`model.settings`, read only
     by the caption and Revert, which now goes back to what is on disk). Test
     `fixedIsLouderOnlyAfterSoftwareVolume` (new API; MUTANT: the old rule FAILS it on "software with a
     volume control"), plus the pin that Software and Fixed give the same engine arguments.
  3. **`dsdRate` after the idle release** — VERIFIED: `ca.track_rate`/`ca.track_fmt` outlive the release
     (kept on purpose, `SILENCE FORMAT IS NOT A FINDING`), so no new line came, and a DAC stays at its last
     rate (§B TWO RATE SWITCHES, steady state). The menu read "DSD64 · DoP" for a released FiiO, and over
     another app's PCM at 176.4k (writer: the FiiO chosen in that app; not seen). FIX: `ca_report_format`
     also says `lyrionplay:format idle` once when `ca.dev` is unknown (read under the output lock, as every
     write of it is), and says the rate again on the next open; the agent's `FormatLine` drops the report.
     Frames unchanged (the report only reads; the matrix passes). Tests: engine "the idle release is
     reported" (FAILED on the pre-fix engine: no idle line, nothing said after it), MUTANT (idle said every
     pass) fails it and "what plays is reported once per change"; swift `theReleaseDropsTheReport`.
     Carriers: `ca_report_format` has one caller (slimproto.c:751); `ca.dev` is written under the lock
     (init aside); `engineFormat` is read only by `writeStatus`, `dsdRate` only by the menu's output line;
     `VolumeReport` does not take the idle line. A failed reopen now says idle, then the rate on the
     retry's open: correct.
  4. **The send's result thrown away** — DROPPED (`A STALLED SERVER IS NOT A FINDING`): a set answers
     `{"result":{}}` (`A SET ANSWERS AN EMPTY RESULT`), so a nil send is a request with no HTTP answer
     while the read-back ms later is answered: a late or lost answer. Re-raise only with one seen in agent.log.
  5. **`volumeRestore` silent on a failed read** — DROPPED for the same reason. Its suggestion (take
     "before" from the check's `status`) is SOUND, measured (`A SET ANSWERS AN EMPTY RESULT`: status's
     `mixer volume` is the saved pref) but NOT BUILT: one request saved on a rare path (a mode change),
     against code verified live on 2026-10-12.
  6. **"bring LMS's fixed setting along now"** — VERIFIED in agent.log 2026-10-12: changes at 08:09:12 and
     08:09:56, synced at 08:09:18 and 08:10:02, both a Device <-> Fixed change that restarts the engine.
     The comment was the defect: FIXED (main.swift and §A2). No code change: the restart already stops the
     player (§B, the put-back's live run), so the 6 s fall while nothing plays; the switch's delay is the
     known "not instant" in §A2. Which of "not yet connected" or "a check already running" skipped it was
     not measured; the comment says only what the log shows.
  7. **`ca_report_format` takes the output mutex again** — TRUE (`LOCK` and `LOCK_O` are both
     `outputbuf->mutex`), DECLINED: two loads under the lock once per ~100 ms pass, beside the same thread's
     longer `LOCK_O` section just before it; the fix moves the read into upstream's slimproto.c block, a
     second edit to an upstream file for no measurable gain.
  8. **The redundant `lastLMSCheck = .distantPast` on a server change** — TRUE, DECLINED: harmless, and
     each write states its own reason; removing one is what would let the edit the finding describes drop
     the server check.
  9. **The format test's statics** — WRONG, `EACH ENGINE TEST IS ITS OWN PROCESS`.
  10. **Stale ledger lines** — VERIFIED (index row, §A2, two §B lines said 0.3.0 not live-tested / not
      installed): FIXED, with what is still owed named.
  11. **The `fixedVolume` lock comment** — VERIFIED (`sent` runs on `syncFixedVolume`'s own task, not
      the check's): FIXED.

- **CODE-REVIEW 2026-10-11 (5) — /code-review of the tree after round 4** (Simon: "lets do a code
  review of LyrionPlayer", then "fix the toolings"; scope by file times, diffed against session
  copies of 0.2.8-0.2.10). NO finding in the engine or the agent: round 4's `#if DSD` guard compiles
  under `-Wall` either way, the reverted finding 1 left nothing behind, the `End` cases pair with
  `ServerChoice.checked`. Four in the test tooling, ALL VERIFIED + FIXED, each anti-run against a
  copy of the old file. After: `scripts/test.sh` PASS. Test-only: NOT built, NOT installed (the
  installed app is 0.2.10, and so is the engine source, `#if DSD` aside).
  1. **`matrix()` counted a scenario whose `fork()` failed** — VERIFIED with every 100th fork failing
     EAGAIN (a scratch copy each): the old runner lost 256 scenarios (25,434 signatures of 25,690),
     judged on a `status` `waitpid` never set (ECHILD matched the pid -1 slot); here they read as
     failed, but a 0 there passes them. FIX: a failed fork closes its pipe and is not counted (retried
     when a child exits); `waitpid` <= 0 waits 100 ms and loops. Fixed copy: 25,690 of 25,690, 0 failed.
  2. **`scripts/test.sh` called a failed conversion suite "died first"** — VERIFIED with a stand-in
     suite printing the conversion summary and `result: FAIL`: old "no summary line: it died first",
     now the `conversion: …` line. FIX: `^conversion:` in both patterns.
  3. **`write_sig` silent on a failure; `MATRIX_ONE` wrote none** — VERIFIED: `MATRIX_SIG` naming a
     missing directory, the old suite PASSED with no file written; `MATRIX_ONE` wrote nothing. FIX:
     `sig_dir_ok` fails the matrix first; a file that cannot be written (or a path too long, a write
     error at `fclose`) fails its scenario with "signature not written: <path>: <reason>" (tested with
     a directory in the file's place); `MATRIX_ONE` writes its signature.
  4. **The signature could not show a changed frame** — it held run, rate, kind, length, tail and off
     per segment. FIX: the track (`#N`) for music and an FNV-1a hash of every sample's bits
     (`seg.hash`, kept by `record`). Run on the current engine and on 0.2.10: every difference was a
     synced start's timing (`THE MATRIX IS FRAME-EXACT BUT ONE`, corrected), none hash-only; and the
     two compile to the same 4,480 instructions (`otool -tV`, `-DDSD -O2`), differing only in log
     `__LINE__` constants moved by round 4's comments. Round 4's "frame for frame" CORRECTED there.
  - **Dropped at the gates:** the file header and OFF comment say silence "in `_silence_fmt`'s
    format", which exists only under `#if DSD` (no writer: `Makefile.coreaudio` always sets `-DDSD`;
    and `SILENCE FORMAT IS NOT A FINDING`); LMS-check log lines that differ only with a late answer
    (`A STALLED SERVER IS NOT A FINDING`).

- **CODE-REVIEW 2026-10-11 (4) — /code-review of 0.2.9-0.2.10** (Simon: "lest code review lyrionPlayer";
  not a git repo: scope by file times, diffed against session copies of 0.2.8 and 0.2.9). Five findings,
  then Simon: "verify all, test 1 is an issue then fix and test". ALL 5 VERIFIED; 2-5 FIXED; 1 fixed,
  then REVERTED on Simon's decision (`SILENCE FORMAT IS NOT A FINDING`). Gates: none in the index, §A3
  or §C; none version-dependent. After the revert the engine differs from 0.2.10 only by finding 2's
  guard and finding 5's comments, and plays frame for frame as 0.2.10 (`MATRIX_SIG` diff against a
  0.2.10 copy: 25,690 scenarios, 0 differ) [CORRECTED by `CODE-REVIEW 2026-10-11 (5)`: that signature
  held each segment's run, rate, kind and length, not its track or samples, so it proved the same
  segments, not the same frames. The claim stands on other evidence: the compiled engine is 0.2.10's
  instruction for instruction]; `scripts/test.sh` PASS (engine output 41/41 with the
  matrix; swift 55 tests in 15 suites; install.sh 3/3); compiles with and without DSD under `-Wall`.
  NOT built, NOT installed: the installed app is 0.2.10.
  1. **`ca.track_rate`/`ca.track_fmt` outlived the idle release** (engine) — VERIFIED in the fake HAL
     only. After DSD64 and the idle release, a 176.4k PCM album from idle stopped inside the open or
     while it buffered got DoP silence after the stop (the first a 0.2.9 change, the second older).
     On the rig it needs a 176.4k PCM stream after DSD64 (not sold), or DSD128 then DSD256, and a stop
     in that window; the effect is DSD silence while nothing plays. Two fixes were built: (a) the
     record started afresh at an open of a closed device, (b) set by a track due at the device's
     rate. (a) alone changed 88 scenarios for the worse, found only by a frame diff of every scenario
     against 0.2.10 (`MATRIX_SIG`, added for it, kept). Then Simon: "look at the DSD playback
     properly. Test in all scenarios via the DAC to see if they really are a problem", the DAC test
     below, his own test ("Ive tested myself swithcing to pretty much most formats no silence its not
     needed"), and the decision: REVERTED; its tests, matrix invariants 9-10 and `I_PAUSE_IDLE`
     removed.
     - **DAC TEST, installed 0.2.10 run by hand with `LYRIONPLAY_TAP`, FiiO, 2026-10-11 21:10-21:29
       local** (Simon: FiiO, installed 0.2.10). Run 1, A1-A4 (DSD64, idle release, then 44.1k; 44.1k
       stopped in the open; DSD256 as 352.8k PCM; DSD256 stopped in the open): every open as expected;
       the tap held music from frame 0 at the right rates, DoP silence to each close after DSD, zeros
       after the PCM stops (A2 is round 3's case: zeros, PASS). Simon heard NONE of it, though the
       FiiO took every frame (the HAL clocked the IOProc throughout); his own DSD256 play at 21:17
       through the same engine was heard. Run 2: the FiiO dropped off USB at 21:21:27, 2.4 s into
       44.1k after DSD64 and an idle release (macOS: USB-C CC detach, "FiiO M11 Plus: hardware
       connection lost"; no USB error before it; coreaudiod and usbaudiod kept their PIDs) and came
       back at 21:23:26; Simon: not unplugged. It dropped the same way at 17:22:37, after the 0.2.9
       live test. NOT INVESTIGATED (Simon: "can we just get on and test the dac leave investigating
       this"). The hand-run engine does not notice a device that vanishes while open (no IOProc, still
       "open"); the agent does (`AudioDeviceWatcher` stops the engine, starts one when it is back).
  2. **`dsd_format track_fmt` outside `#if DSD`** (engine) — VERIFIED: 0.2.10 without `-DDSD` stops
     at "unknown type name 'dsd_format'". FIX: the field under `#if DSD`, its writes `IF_DSD`; the
     file compiles with and without DSD, no warning under `-Wall`. Only `Makefile.coreaudio` builds
     the engine (it always sets DSD), so no shipped build was affected.
  3. **`Duration.seconds` extension** (PlayerCore) — VERIFIED: the standard library's
     `Duration / .seconds(1)` gives the same 2.6 and 4.003. FIX: the extension and its test
     `durationsAreSeconds` removed; `refreshLMS` divides.
  4. **`ended(_:found:answer:took:)` took both times** (PlayerCore) — VERIFIED: a kept check read
     only `answer`, a dropped one only `took`. FIX: each `End` case carries its own
     (`.kept(answered:answer:)`, `.dropped(began:now:took:)`); `ended(_:found:)`.
  5. **The OFF-branch comment** (engine) — VERIFIED: OFF lasts until slimproto acts on the reopen
     (one IOProc call or more), and `aude` (power off) sets OFF while a track buffers, so the silence
     can be a pending track's. FIX: the OFF comment and the file header.

- **CODE-REVIEW 2026-10-11 (3) — /code-review of 0.2.8** (Simon: "lets do another /code-review";
  scope by file times since the 0.2.7 install, diffed against a session copy of 0.2.7). Six findings.
  Then Simon: "verify and fix, we seem to be gettig repeated regessions with the rate change and
  silence, we need to be more thorough here". ALL 6 VERIFIED + FIXED. Gates: none in the index or §A3, none version-dependent; 2-4 are about the
  agent.log lines (the round (2) class), not a stalled server: their writers are a server that has
  gone (4 s timeout) and Mac sleep. After: `scripts/test.sh` PASS (engine output 40/40 with the
  matrix, 3 runs; swift 56 tests in 15 suites; install.sh 3/3); the agent builds (its one warning is
  the known `SendableClosureCaptures`).
  - **INSTALLED as 0.2.9, 2026-10-11 15:53Z** (Simon: "yes" to version up and install; 0.2.8 -> 0.2.9
    with `bump-version.sh patch`; `build.sh --install`, suite PASS inside it; `prodmac46` checked
    connected and stopped first). install.sh: "version 0.2.9 (was 0.2.8)"; agent.log "agent started:
    LyrionPlay 0.2.9 (202610111653)", the engine restarted on the FiiO (`output_init_coreaudio:1309`,
    the new source's line; 0.2.8's was 1295), then ONE "LMS: using Simons Music (192.168.1.234:9000)";
    LMS: prodmac46 connected. NOT live-tested: a late LMS answer (needs a stalled server: not staged,
    as decided).
  - **Finding 1 VERIFIED LIVE on the FiiO, 0.2.9, 2026-10-11 17:12-17:13 local** (Simon: "test it",
    player prodmac46 on the FiiO). The agent booted out; the INSTALLED engine run by hand on its
    agent.log arguments plus `LYRIONPLAY_TAP`; playback by a session script over LMS JSON-RPC (mode
    checked before each command); the agent re-bootstrapped after, engine on its normal arguments,
    prodmac46 connected, the queue (The Roots 816519) as before. DSD64 (827020) played 29 s and was
    stopped; the idle release 30.5 s later ("output off", `err = true`, so `error_opening` set);
    then 44.1k (816519) from idle, with `stop` sent on the `device rate 44100` line: flush at
    22.534, INSIDE the open (device rate 22.517 -> opened 23.223), no track start. That flush reset
    `current_sample_rate` to 44100 (the FiiO's default: `output_init_common` prefers 44100) with
    `outfmt` still DOP, which is 0.2.8's DoP-silence case exactly. TAP at 44.1k: 624,640 of 624,640
    frames PCM zero. PASS. (No live anti-run: a 0.2.8 binary would be a new executable, and Local
    Network approval is per executable. The suite's test is the anti-run: it fails on 0.2.8.)
    The DSD64 tap: DoP from frame 0, DoP silence (0x69) from the stop to the release.
    - **THE IDLE RELEASE'S LAST CALL WAS ZERO — seen there, FIXED 2026-10-11 (Simon: "fix it"),
      INSTALLED as 0.2.10 2026-10-11 18:33Z** (Simon: "yes" to version up and install; prodmac46
      checked stopped first; `build.sh --install` suite PASS inside it, "version 0.2.10 (was
      0.2.9)"; agent.log "agent started: LyrionPlay 0.2.10 (202610111933)", engine restarted on the
      FiiO at `output_init_coreaudio:1318`, the new source's line (0.2.9: 1309), ONE "LMS: using
      Simons Music"; prodmac46 connected). **VERIFIED LIVE on the FiiO, 0.2.10, 2026-10-11
      19:35-19:36 local** (Simon: "live test", player prodmac46 on the FiiO; the same rig as the 0.2.9
      test: agent booted out, the installed engine by hand with `LYRIONPLAY_TAP`, mode checked before
      each command, the agent re-bootstrapped after, prodmac46 connected, queue The Roots as before).
      DSD64 (827020) 10 s, stop, idle release: the 176.4k tap holds NO zero frame (1,772,025 DoP
      music, 5,328,903 DoP silence), its last frames DoP silence (05/FA over 0x6969) to the close
      (0.2.9: the last 512 zero). Then 44.1k (816519) from idle, `stop` on `device rate 44100`: flush
      at 56.106 inside the open (56.082 -> opened 56.778), and the 44.1k tap 1,324,544 of 1,324,544
      frames zero to the second release: finding 1 again, and the PCM half (zeros to the close). PASS.
      Before the fix: the LAST IOProc buffer before the idle release
      (512 frames, 2.9 ms at 176.4k) was PCM ZEROS after DoP silence. At `OUTPUT_OFF` the IOProc
      skipped `_output_frames` and left its zeroed buffer, then asked for the close. Upstream's
      PortAudio callback still calls `_output_frames` at OFF (`output.state <= OUTPUT_BUFFER` gives
      silence, in `outfmt`: DoP silence), then `paComplete`. So a DoP DAC got 2.9 ms of markerless
      data at the very end of every idle release after DSD (and an LMS power-off after DSD). Not a
      regression: the OFF guard predates the reviews. The matrix exempted it through `boundary_pad`
      (a call that asks for a reopen may pad its tail with zeros), written for the rate-change pad,
      where upstream pads zeros too. Simon heard nothing wrong in the 0.2.6 DSD tests, each of which
      went through this release.
      FIX: at OFF the IOProc calls `_output_frames` (off, it plays only silence: no track start, no
      fade, no frames played; output.c read through), so the silence is `_silence_fmt`'s: DoP
      silence after DoP at its rate, zeros after PCM. The rate-change pad stays zeros (upstream's
      too). Carriers checked: the reopen trigger below it unchanged; the tap records what is sent; an
      LMS power-off with music buffered (`aude`) gets silence, not the music, as before (zeros) and as
      upstream; gain is not applied to silence. UPSTREAM.md "Updating" lists the OFF rule to re-read.
      Tests: "the idle release keeps the silence of what played to the close" (DoP half FAILED on the
      unchanged engine with 512 of 512 zero, the tap's own count; PCM half: control); the matrix
      records each call's OFF state (`tickinfo.off`) and `boundary_pad` no longer covers an OFF call:
      unchanged engine 16,784 of 25,690 scenarios FAIL ("zeros after track N (DoP)"), fixed 0.
      Mutant (OFF always DoP silence): the test's PCM half and 18,400 scenarios FAIL ("DoP silence
      at a rate no DoP track plays at"). After: `scripts/test.sh` PASS (engine output 41/41, swift
      56, install.sh 3/3).
  1. **`_silence_fmt` after a flush from idle** (engine) — VERIFIED by test through upstream's real
     `output_flush`: after DSD64 and the idle release (`error_opening`), a stop inside the open, or
     before the monitor's look, left the device at 44.1 kHz with `current_sample_rate` reset to the
     default and `outfmt` still DOP: 512 of 512 frames DoP silence (tests "a stop inside / before the
     open after DoP leaves PCM silence"; they also fail on 0.2.5 and 0.2.7: older than round 1's fix).
     Writer: a stop, next or new album inside ~100-250 ms of a play from idle after a DSD track. FIX:
     the IOProc records the rate and format of each track start output.c takes (`ca.track_rate`,
     `ca.track_fmt`; `track_start` going NULL inside the locked `_output_frames` call) and
     `_silence_fmt`'s second rule reads that, not `current_sample_rate`/`outfmt`. No other reader of
     the pair changed (`_write_frames`' music, `_start_delay`, `_rate_ok`, `_mark_switch_done` keep
     output.c's own state, as upstream).
     - **Seen while there, not changed (upstream's own, as PortAudio):** with a rate delay set, the
       same reset makes output.c see no rate change for that album, so it gets no delay silence
       although the DAC switched at the open. Writer: "Silence on a rate change" > 0 (off by default
       and on the rig) plus that ~250 ms window.
  2. **A run ended by another target; the 4 s line** (agent) — VERIFIED (anti-run of 0.2.8's
     `LMSCheckLog`, the new tests' sequences): see `THE 4 S LINE SAW ONLY TIMEOUTS`. FIX: the time is
     the server's answer to the players and status requests (not discovery's 2 s wait), slow over 2 s
     (`slowAnswer`, the tick); a run belongs to one server (another, or none, ends it unsaid, as a
     setting change does); "back under 2 s". Tests `aLateAnswerIsLogged`,
     `aServerGoneIsItsSlowLineAndDidNotAnswer`, `aRunEndsUnsaidWhenAnotherServerIsChecked` (all three
     differ on 0.2.8). A typed host that does not answer is now "took 4.0 s" (the request), not 6.0.
  3. **Sleep and a busy main queue counted as LMS time** (agent) — VERIFIED in part by a probe: a
     50 ms check finishing while the main queue was busy 3 s measured 3.01 s the old way (Date after
     the hop), 0.06 s the new (`SuspendingClock` in the task). The sleep half rests on
     `SuspendingClock`'s documented behaviour (it stops while the Mac sleeps), not measured (no sleep
     of Simon's Mac). Structure keeps the agent on it (the timing is in `refreshLMS`'s task); test
     `durationsAreSeconds` pins only the conversion. [Removed in CODE-REVIEW 2026-10-11 (4): the
     standard library's `Duration / .seconds(1)` does it.]
  4. **The control at took 4.0** — VERIFIED: with 4.003 (what a 4 s timeout takes) 0.2.8 wrote the
     false "checks of no server back under 4 s" line the control hid. All tests now use 4.003.
  5. **The test `flush` without the `error_opening` rule** — VERIFIED, and the root of 1 slipping
     through, with round (2) finding 4 (another rule missing from the hand-made `_output_frames`).
     FIX, for the class: the suite links upstream's `output.c`, `buffer.c`, `output_pack.c` and
     `dop.c` unchanged; the hand copies are gone (fakes left: `dsd_silence_frames`, `dsd_invert`,
     `next_param`, the clock and log). The staged tests that set `outfmt`/`current_sample_rate` by hand
     now PLAY the last track through the real path (`play_track`, `idle_release`). All 37 earlier
     tests pass on the real `output.c`. UPSTREAM.md "Updating" rewritten (run the suite; the rules
     to re-read, `error_opening` and strm f's `track_start` among them).
  6. **`End.kept(server:)` + `found`, `named: LMSServer??`** — FIX: `.kept(answered:)`, a `Said` enum,
     a `Run` struct.
  - **SCENARIO MATRIX** (the "more thorough" part): `./test_output_coreaudio matrix`, run by the
    suite. 25,690 scenarios: last track (none, 44.1k, 96k, 176.4k PCM, DSD64, DSD128 as DoP) x the
    device kept, let go, or let go and moved to 48 kHz by another app x next track x the decoder
    before the monitor's look, during its wait, or after the open x a stop, a new album, a stop then
    a new album (with or without the idle release between), a pause, a synced start, at the points
    before the look / in the wait / inside the open / buffering / playing x rate delay 0 or 200 ms x
    a gapless follower x a slow stream. Driven by `strm` q/s/p/u as slimproto.c runs them, the
    monitor gated so an event lands at an exact point. Each frame the device gets carries its track
    and position; invariants (`check_invariants`), none of which restates the engine's rule: no DoP
    silence at a rate no DoP track plays at; each track's music only at its rate, in its format, in
    order, all of it unless stopped; inside a track, after it (to the idle release's close, since
    the 0.2.9 live test) and before it (once due) its own silence; the delay never longer than set, and both halves between gapless tracks; one rate
    switch when the decoder was in time; no reopen to a rate nothing then uses. ~10 s on 8 cores.
    - **It catches every silence/rate bug the reviews found, on the engine that had it:** 0.2.5
      copy 5,992 failures (round 1's DoP silence at a PCM rate, stretched delay after a flush, the
      lost first half, the flushed track read as pending; round (2)'s format at the last rate);
      0.2.7 copy 2,840 (round (2)'s); 0.2.8 1,552, all finding 1 here; fixed: 0. (Counted with the
      matrix of that day; the idle-release check added after the 0.2.9 live test fails 16,784 on
      0.2.9 itself, so older copies now fail more.)
    - **Mutants** (each one rule of the fix or of earlier fixes broken, `OCA_SOURCE`): 10 of 10 fail the
      matrix on its own (pending first; the lock; the lock by `current_sample_rate`; the delay mark;
      `_track_pending` without frames; `_rate_ok`'s empty clause; the open at the pending rate; the
      decoder wait; the IOProc's break at a rate change; and, with the idle-release fix, OFF always
      DoP silence: 18,400). Three only after adding the moved-DAC gap
      and the wasted-reopen check, which is why those exist.
    - **Matrix bugs found and fixed while building it** (none in the engine): a 2 s stall per
      scenario (the gate waited on a condition no one signalled), a delay bound counted across a
      flush, a wait-scenario that never decoded its track (now check 0), a reopen check that took the
      monitor's open after an idle close for a switch.
  - **Checked and CLEARED (do not re-derive):** *a synced start passes through `OUTPUT_BUFFER`:*
    no. autostart 0 sets `_sendSTMl`, never `_start_output` (slimproto.c:676-684), and only
    `_start_output` moves STOPPED/OFF to BUFFER (slimproto.c:723); `strm u` then goes straight to
    `OUTPUT_START_AT`. The synced-start test's comment is right.

- **INLINE REVIEW 2026-10-11 — after CODE-REVIEW 2026-10-11 (2)** (Simon: "lets do an inline review").
  Scope: everything that round changed (agent `refreshLMS`/`tick`, `LMSCheckLog`, `_silence_fmt`,
  `_at_pending_rate`, the test fake, the new tests) plus the docs.
  - **Stale refs, FIXED:** `scripts/test.sh`'s header did not list the server choice or the log-line
    suites (`ServerChoosing` was missing since 0.2.5); "the way to see one" lacked round 2's rules
    (a dropped check is one line and no part of a run; a setting change ends a run unsaid).
  - **One wording nit, FIXED (my own round-1 text; Simon: "yes"):** "LMS checks of X quick again
    (N s) …" also ended a run with a quick FAILURE (a stall, then LMS restarting: connection refused
    in ms), so it read as "answering again" next to the "did not answer" line under it. Now "LMS
    checks of X back under 4 s (N s), after K slower, the slowest M s". Test
    `aStallEndingInAQuickFailureSaysUnder4sNotAnswering` (failed on the old text; renamed
    `…Under2s…` with the 2 s line in CODE-REVIEW 2026-10-11 (3)).
  - **Checked and CLEARED (do not re-derive):**
    - *`checkLog` from two threads:* no. The tick timer is on `.main` (`makeTimerSource(queue:
      .main)`) and a check's completion hops to `DispatchQueue.main`; `settingChanged` and `ended`
      run on one thread.
    - *A setting changed and changed back during a check:* `update` calls `settingChanged` twice;
      the check (begun with the setting in force again) is KEPT, and its line is written because
      `named` is unset. Correct: it is the first check after a change.
    - *`_silence_fmt` pending-first while paused or waiting:* `_track_pending` needs `readp ==
      track_start` AND frames in the buffer. A pause mid-track is not pending, so a DoP track's
      pause keeps DoP silence (upstream's lock). A pause (`strm p`, with or without an interval)
      exactly AT a same-rate format boundary now plays the new format's silence: silence either
      way, and the DAC relocks before the music. An underrun cannot be pending (empty buffer).
    - *A fallback server (`LMSServer(host:, 9000, nil)`) after a discovered one (name set):* not
      equal, so one "LMS: using plex (plex:9000)" line on such a flap. It IS a change of what the
      agent uses, written once; accepted.
    - *`reopen()` right after `start(…, idle 0)` in "the rate delay between DoP tracks is DoP
      silence":* `output_init_coreaudio` opens synchronously under the lock with idle 0 (state
      STOPPED), no monitor, so the two opens cannot overlap.
    - *The fake's pause frames go to RUNNING in the same call; output.c on the next:* the next call
      takes the start either way; same frames, same halves (the 2.00 s controls pass).
    - *The build's one Swift warning, `main.swift:397` "capture of 'self' with non-Sendable type
      'Supervisor?' in a '@Sendable' closure" [SendableClosureCaptures]:* HARMLESS, and older than
      this round (0.2.7 has the same `Task.detached { [weak self] … DispatchQueue.main.async { guard
      let self`). The detached task only carries the weak reference; every `Supervisor` read and
      write is on the main queue (above). A warning because the package is Swift 5 mode
      (`swiftLanguageModes: [.v5]`); Swift 6 mode would make it an error. The real fix is
      `Supervisor` as `@MainActor` (touches the signal handlers, device watcher, volume sender);
      `@unchecked Sendable` would only silence it. Neither built; not a defect.

- **CODE-REVIEW 2026-10-11 (2) — /code-review of 0.2.6-0.2.7** (the 0.2.6 engine fixes, `ServerChoice`,
  0.2.7's agent.log lines; scope by file times, no git). Six findings; Simon: "fix 1-4 first verify
  first before changing code". Gates: none in the index. 1 and 3 are about 0.2.7's log lines, code
  a fix introduced, not a stalled server (`A STALLED SERVER IS NOT A FINDING` stays as it is).
  Each fix is pinned by a test that FAILED on the old code (agent: anti-run with 0.2.7's rules
  copied into `LMSCheckLog`; engine: the unchanged `output_coreaudio.c`). After: engine output
  36/36 (3 runs), swift 49, `scripts/test.sh` PASS, the engine links.
  - **INSTALLED as 0.2.8, 2026-10-11 14:15Z** (Simon: "install it", "yes" to version up; 0.2.7 -> 0.2.8
    with `bump-version.sh patch`; `build.sh --install`, suite PASS inside it; the player `prodmac46`
    was connected and stopped first). With this round's 5-6 and the inline review's wording fix.
    agent.log: "agent started: LyrionPlay 0.2.8 (202610111515)", engine restarted on the FiiO
    (`output_init_coreaudio:1316`, was 1310: the new binary), then ONE "LMS: using Simons Music
    (192.168.1.234:9000)" at the first check and no further LMS line while checks ran. NOT seen live:
    a slow server (not staged, as decided).
  - **LIVE TEST of 0.2.8, 2026-10-11 15:22-15:31 local** (Simon: "test the build", "all of what was
    changed", "use prodmac dont worry about the queue clear it"; FiiO knob down):
    - **Findings 1 + 3, VERIFIED LIVE:** settings.json backed up, server set to 192.0.2.1 (TEST-NET)
      at 14:22:11Z. agent.log in the next 72 s (~11 checks of 6 s): ONE "LMS check of 192.0.2.1
      (192.0.2.1:9000) took 6.0 s" and ONE "LMS: 192.0.2.1 (192.0.2.1:9000) did not answer" (0.2.7:
      ~11 "took" lines and no server line). Restored byte-identical (`cmp`): ONE "LMS: using Simons
      Music (192.168.1.234:9000)" and NO run-end line (a setting change ends the run unsaid,
      VERIFIED). Player connected again. Side note, not from this round: the engine pointed at
      192.0.2.1 did not stop on SIGTERM in 3 s and the agent SIGKILLed it (by design, its connect).
    - **Finding 2, NOT REACHABLE on this rig:** no 176.4k PCM exists in the library (Simon: 176.4k
      is not a PCM recording rate; 44.1/48/88.2/96/192 are) and no DSD128. Staged instead as a 192k
      DAC: the INSTALLED engine by hand as prodmac46 on the FiiO, `-r 192000,176400,96000,88200,48000,
      44100 -Z 192000`, `LYRIONPLAY_TAP`. DSD64 -> DoP 176.4k; DSD256 -> "DSD to PCM output",
      "resampling from 1411200 -> 176400" (resample.c: the first rate dividing 1411200): the
      review's same-rate pair, from real albums. Four plays from idle, each after `output off`:
      DSD64 (827020) after 44.1k; DSD256 (827002) after DSD64 [finding 2]; DSD64 after it [reversed];
      44.1k (816519) after DSD64 [0.2.6 finding 1]. Each ONE open at the expected rate, decoder
      first. TAP: music from frame 0 in ALL FOUR (DoP markers with a varying payload, or PCM data;
      checked raw, not only by the classifier): no buffering silence reached the device, so the
      silence format did not matter. The window needs buffering to outlast the open: a slow stream
      or a synced start's wait, neither stageable here with DSD. The fix stands on its tests;
      no regression in the four from-idle paths. The rig restored after: agent re-bootstrapped,
      engine on its normal arguments, LMS connected; the queue holds the last test track.
  1. **A line per check for a server that does not answer** (agent) — VERIFIED by MEASUREMENT: the
     agent's own `LMSDiscovery.find` + `playerState`, compiled in a session probe, against
     192.0.2.1 (TEST-NET, nothing answers): 2.00 s discovery + 4 s timeout = 6.0 s, three of three
     checks; the rig's LMS 0.01-0.04 s. Over the 4 s line every time, and the next check starts at
     once (began > 5 s ago), so one line every ~6 s until a restart (rotation only at start). FIX:
     `LMSCheckLog.timed`: the first slow check of a run, and one line when the run ends (count,
     slowest). Tests `aServerThatDoesNotAnswerIsLoggedOnceNotPerCheck`,
     `aStallIsLoggedWhereItBeginsAndWhereItEnds`.
  2. **`_silence_fmt` at the last track's rate** (engine) — VERIFIED by test: `outfmt` was taken
     whenever the device was at `current_sample_rate`, so a play from idle at the LAST track's rate
     in the other format waited in the last track's: DoP silence (1024 of 1024 samples) before a
     176.4k PCM album after DSD64, PCM zeros before DSD64 after 176.4k PCM. The same on a synced
     start (autostart 0, `strm u`: `OUTPUT_START_AT`, never `OUTPUT_BUFFER`). FIX: the pending track
     first. Gapless: differs from output.c only inside a DSD delay, whose first half then plays in
     the new format; NO WRITER (the app passes a bare `-D`, `dsd_delay` 0), so no state gate or DSD
     delay mark was built. Tests "a play from idle after DoP at its rate buffers in PCM silence",
     "a play from idle into DoP at the last rate buffers in DoP silence", "a synced start waits in
     the pending track's format".
  3. **No server line at start or after a setting change** (agent) — VERIFIED from the code:
     `self.lms.server != before`, and both the agent's start and `update()` leave the server nil,
     so a check that found none compared nil with nil. FIX: `LMSCheckLog.uses` compares with the
     last server it NAMED, unset at start and by `settingChanged()` (called where `update` returns
     true). Tests `noServerAtStartIsLogged`, `aChangedSettingThatDoesNotAnswerIsLogged`; control
     `eachChangeOfServerOnce` (passed on both).
  4. **The fake wrote no pause or start-wait silence** (tests) — VERIFIED: with the old fake the
     DoP rate delay test read 345 + 690 calls of zeros, and the synced-start test PASSED on the
     unfixed engine because the fake wrote nothing for `OUTPUT_START_AT`. FIX: the fake sends pause
     frames (capped at `MAX_SILENCE_FRAMES`, as output.c) and `OUTPUT_START_AT` through `write_cb`;
     an underrun while running is still not modelled (said in the fake's comment). Test "the rate
     delay between DoP tracks is DoP silence" (DSD64 -> DSD128, gapless, 2000 ms: both halves DoP;
     passes on the unfixed engine: it was only the fake). UPSTREAM.md "Updating" lists both.
  Then Simon: "yes" to 5 and 6 (the same session, verified first again). After: engine output 37/37
  (3 runs), swift 51, `scripts/test.sh` PASS, the engine links.
  5. **A slow AND dropped check wrote two lines** (`took`, then `dropped after`) — VERIFIED from the
     code (round 1 kept it: `timed` ran before the drop was known). FIX: `LMSCheckLog.ended(_:took:
     found:)` decides all the lines of a check; a dropped check is ONE line with its time and is no
     part of a run (it checked a setting no longer in force); `timed`/`uses` are private.
     `refreshLMS` asks `lms.checked` first, then logs. Test `aSlowDroppedCheckIsOneLine` (failed on
     round 1's flow, copied into `ended` for the anti-run).
     - **Found while there, in round 1's own code:** `settingChanged()` left a slow run going, so the
       new server's first quick check wrote "LMS checks of <NEW> quick again … after K" for checks of
       the OLD one. FIX: a setting change ends the run unsaid (the "LMS: using" line follows). Test
       `aSettingChangeEndsTheRunUnsaid` (failed on round 1's rules).
  6. **The pending-rate predicate written three times** — VERIFIED (lines 793, 854, 866). FIX:
     `_at_pending_rate()` beside `_track_pending` (moved up, the forward declaration gone), used by
     `_silence_fmt`, `_rate_ok`, `_mark_switch_done`. No behaviour change: 36/36 before and after.
     The suggested saving of repeated `_track_pending`/`_buf_used` calls was NOT built: they are a
     few compares, and caching across `_output_frames` (which moves the state) would be a risk for
     nothing. MUTANT (rate clause dropped, `OCA_SOURCE`): only ONE test failed, and none pinned the
     silence format while the device is NOT at the pending rate. Test added: "a slow decoder into
     DoP buffers in PCM at the last rate" (decoder past the 150 ms wait, device opened at 44.1k, DSD64
     pending: DoP silence there is noise); the mutant now fails two.

- **CODE-REVIEW 2026-10-11 — /code-review of 0.2.3-0.2.5** (the pending-rate open, the 150 ms wait, the
  `delay_active` fix, `ServerChoice`; Simon: "verify them first then fix and test"). Seven findings.
  Each fix is pinned by a test that FAILED on the pre-fix `output_coreaudio.c` (anti-run with
  `OCA_SOURCE`, a session copy) and passes now: engine output 32/32 (5 runs), swift 44 tests, all
  suites PASS; the full engine links. **INSTALLED as 0.2.6, 2026-10-11 09:39Z** (Simon: "bump and install";
  player was stopped, FiiO not held; agent.log "LyrionPlay 0.2.6 (202610111038)", LMS connected).
  1. **DoP silence at a PCM rate** — VERIFIED by test: after a DoP track, a play from idle opened at
     the PCM track's rate while `outfmt` was still DOP (it changes at the track start, output.c:159;
     `output_flush` leaves it), so `_write_frames` played `silencebuf_dsd` + markers as PCM for the
     whole buffering: 0x05/0xFA over 0x6969 = a square wave at Nyquist, about ±0.043 FS (-27 dBFS).
     1024 of 1024 samples non-zero on the old code. Default settings; DSD->PCM from idle was never
     tested live (only PCM->DSD). FIX `_silence_fmt`: the format of what plays at the device's rate
     (`outfmt` at `current_sample_rate`, `next_fmt` at the pending track's, else PCM). Tests "a play
     from idle after DoP buffers in PCM silence"; "a play from idle into DoP buffers in DoP silence"
     (the pending DoP track's silence locks the DAC before the music: a choice, zeros on the old
     code); control "DoP silence at the DoP rate is kept" (upstream's lock, passes on both).
  2. **The rate delay mark lost on a flush** — VERIFIED by test: the mark was set once in `_ca_open`;
     a new album picked while the first buffered (strm q: `output_flush` clears `delay_active`) kept
     the device at the new rate (`buf_flush` puts `readp` back at the start, where the flushed
     `track_start` still pointed, so `_rate_ok` held), and the next start stretched the first half
     again: 3.18 s, not 1.00 (96k -> 44.1k, 2000 ms). Only with "Silence on a rate change" > 0.
  3. **The mark left set with nothing to take it** — the reviewer's path (a track at the OLD rate
     picked during the open) does NOT occur: `_start_delay()` is evaluated under the relock, live, and
     is 0 then. The real one: a STOP during the open (no new track yet) leaves `track_start == readp`
     and the stopped track's rate, so `_start_delay()` was non-zero and the mark was set; the next
     album at the last rate took no delay, and a later gapless rate change got 0.00 s of silence
     before the switch, not 1.00. VERIFIED by test in that form.
     ROOT of 2 and 3, and of the old "stale `track_start` costs one reopen": a flushed `track_start`
     read as pending. FIX: `_track_pending` also needs frames in the buffer (every decoder sets
     `track_start` and the rate before writing the first frames; a flush empties the buffer);
     `_rate_ok` lets a stopped/buffering output with an EMPTY buffer play silence at any rate (else
     the flush in 2 would now force a reopen); the mark moved to the IOProc, `_mark_switch_done`,
     set from live state before each `_output_frames` call, so a flush is followed. Tests "the rate
     delay is not stretched after a flush while buffering", "a stop during the open leaves no rate
     delay mark", "a play after a stop while buffering opens at its own rate" (the monitor's wait
     took the flushed track as found and opened at its rate at once).
  4. Test gaps — the five tests above. The fake `_output_frames` now writes buffering silence through
     `write_cb`, models the DSD delay clause and the `outfmt` switch; the fake DAC takes 176.4k.
  5. **`_start_delay` copies output.c's rule (and the fake a third time)** — true; the suggested shared
     helper in output.c was NOT built: it edits an upstream file the fork keeps untouched, and the
     suite does not link output.c, so the fake keeps its copy anyway. Pinned instead in UPSTREAM.md
     "Updating": re-check `_start_delay`, the fake, `flush`, `_silence_fmt` against a new output.c.
  6. **A dropped check waited out the 5 s cadence** (agent) — VERIFIED from §B's live run of the
     2026-10-10 finding 1: stale reply dropped at 18.28 s, next check 23.43 s. A setting change also
     waited for the cadence. FIX: `update` returns whether the setting changed and `checked` false
     when dropped; either sets `lastLMSCheck = .distantPast` (the next 2 s tick checks). No added
     requests: the same check, sooner.
  7. **`playerState` cleared outside `ServerChoice`** — FIX: `ServerChoice.playerState`, cleared by
     `update` on a change, set by `checked(…, state:)`, `forgetPlayer()` at shutdown. Tests
     "aServerChangeForgetsWhatTheOldServerSaid", "aChangeAndADroppedCheckSaySo" (both new API: they
     do not compile on the old code).
  - **VERIFIED LIVE on the FiiO, 0.2.6, 2026-10-11 10:46-10:52 local** (Simon ran it: "ive done the dsd
    test all good"; engine.log read after). Four plays, each from idle with the FiiO released first
    (`output off` + `exclusive mode released` before every `output on`): DSD64 DoP (176.4k) after
    44.1k: rate found after 40 ms; 44.1k PCM after DSD64: found after 60 ms; DSD64 again: decoder
    first, no wait; 48k PCM after DSD64: decoder first. Every play ONE `device rate` and ONE `opened`
    line, no reopen. The two PCM-after-DoP plays are finding 1's case, and Simon heard nothing wrong.
    [CORRECTED by the 0.2.8 LIVE TEST, 2026-10-11 (`CODE-REVIEW 2026-10-11 (2)`): that proves no
    regression, NOT finding 1. With local files NO buffering silence reaches the device: the
    output tap held music from frame 0 in 4 of 4 plays from idle, incl. 44.1k after DSD64 (this
    case). The buffer fills during the open (~50 ms same rate, ~0.7 s with a FiiO rate switch), so
    the first IOProc call is already running. Finding 1 stands on its test.]
    The stricter pending did not delay the find: 40/60 ms against 0.2.4's 70 ms for DSD64.
  - **Findings 2 and 3 LIVE on the FiiO, 0.2.6, 2026-10-11 14:37-14:38 local** (Simon: "do it"; FiiO
    "Silence on a rate change" set to 2000 ms for the test, engine `-r …:2000`, then back to 0:
    settings.json JSON-identical to the backup, engine restarted with no `-r`; LMS volume left at
    Simon's 100, his knob; playback by a session script over LMS JSON-RPC, not kept):
    - **3, the stop during the open:** fresh engine (last rate 44.1k), George Harrison 192k (795396)
      from idle; `stop` sent on the `device rate 192000` line: flush at 15.790, INSIDE the open
      (15.731 -> opened 16.453), the exact 0.2.5 leak window. Then The Roots 44.1k (816519) + 795396
      gapless: the 44.1k start took no delay (same rate, correct); at the boundary `pause 44100
      frames` 53.012 -> 54.011 (1.0 s BEFORE the switch, at 44.1k), track start 192000, then `pause
      192000 frames` at 192k. 0.2.5 would have had no first half there. PASS.
    - **2, a flush after the open, before the start: NOT REACHABLE on the FiiO.** The window between
      `opened` and `track start` was 8 ms (local FLAC) and 9.5 ms (Qobuz `qobuz://13274.flac`, 44.1k,
      from idle after 192k): the stream fills the buffer during the FiiO's ~0.7 s relock. An LMS
      command cannot land in 10 ms. It needs a DAC with a fast relock AND a slow stream; the suite
      covers it. The same Qobuz play: one switch, then only `pause 44100 frames` (1.0 s): 0.2.5's
      fix still holds.
    - 6 (a stalled server) was not run live; the suite covers it.

- **CODE-REVIEW AFTER 0.2.2 — /code-review of the whole repo, 2026-10-10** (Simon: "Verify these before
  fixing … Then check all code for where changes may hit"). Nine findings; each verified by a
  measurement, the log, or a test that failed on the old code.
  1. **A check begun before a server change brought the old server back** (agent) — VERIFIED by the
     code; narrow writer: the check must outlast one 2 s tick and then answer (LMS answers `players`
     in ~30 ms on the rig, so it takes an LMS stall). Once back, a server that answers was reused for
     good (`known` skips discovery; `playerState` is non-nil even when this player is not listed),
     so the menu and the Mac's volume keys went to the old server while the engine (`-s`) played on
     the new one. Fix `ServerChoice` (PlayerCore): the check carries the setting it began with and
     `checked` drops it if the setting changed; a server change also clears `playerState`. Tests
     `ServerChoosing` (anti-run: `aCheckBegunBeforeAServerChangeIsDropped` fails with the guard
     removed). Structure, not a test, keeps the agent on it, as with `OutputFollow`.
  2. **Mute on a DAC with no mute control** — NO WRITER, see `MUTE HAS A WRITER ONLY WITHOUT A MUTE CONTROL`.
  3. **TWO RATE SWITCHES AT PLAY** (engine) — CONFIRMED in engine.log (FiiO 09:53:07, DragonFly 09:53:58):
     the decoder logged `setting track_start` (48 kHz) 39-46 ms before `output on`; `_ca_open` opened at
     `current_sample_rate` (44.1 kHz, the engine default, `output.c:409`; the review's "the device's
     TOP rate" was wrong) and `set_rate` logged `device rate 44100 Hz after 10 ms`, which it does only
     when it CHANGED the rate. So the engine, not macOS, moved the DAC to 44.1k, and the track start
     reopened at 48k: ~0.73 s later than one open. Simon doubted it ("the OS will set it to its base
     rate"); the log answered it, and he asked for the fix "with care".
     - Fix: `_ca_open` opens at `next_sample_rate` when a track start is the next frame
       (`output.track_start == outputbuf->readp`, `pending`); `ioproc` takes frames while
       `_rate_ok()`: `ca.rate` is the current rate, or that pending track's. Without the second half
       the IOProc would stall and reopen at the old rate at once (anti-run below).
     - Tests: "a play from idle switches the rate once" (FAILED on the old code: "opened at 44100 Hz,
       not the track's 48000"; and on the open rule alone: "the IOProc took nothing while the track
       buffered", "reopen asked"); controls "a play before the decoder opens at the last rate, as
       before" (pins no waiting) and "a gapless track at another rate reopens" (pass on all three).
       The fake `_output_frames` now models output.c's track-start rule.
     - Carriers checked: `_rate_ok`'s second clause is true only when `_ca_open` chose the pending
       rate (at a gapless boundary the device is at the OLD rate, so `ca.rate != next`). In
       `_output_frames` while it holds: buffering threshold uses `next_sample_rate`; the rate delay
       (`-r …:<ms>`) plays its first half counted at the old rate but AT the new one, so the silence
       after the real switch is delay/2 x (1 + old/new), never less than the old code's delay/2; the
       DSD delay is the same mechanism, `outfmt` still changes at the track start; `OUTPUT_START_AT`
       (sync) counts silence at the old rate but recomputes it from the clock each call, so it is
       off by at most part of one IOProc buffer (the old code reopened for ~0.7 s there); crossfade
       (`output.c:328`) compares rates the open does not change. `_ca_open`'s other callers: init
       (no track start), slimproto's gapless reopen (the start already taken, `track_start` NULL or
       later), a resume after the idle release (the next start lies ahead of `readp`). A stale
       `track_start` left by `output_flush` (it does not clear it) can only cost one reopen, as
       [CORRECTED by `CODE-REVIEW 2026-10-11`: from 0.2.5 it also set the rate delay mark; it is no
       longer read as pending at all]
       before. slimproto's STAT elapsed is 0 until the track start. `tools/bitcheck` aligns on the
       first non-zero frame, so the buffering silence now in the new rate's tap file is fine.
  4. **Close while the monitor opens** (engine) — VERIFIED by test: on the old code an IOProc was
     started after `output_close_coreaudio` returned (`main.c` then frees the output buffer and exits).
     Fix: the monitor marks `ca.monitor_opening` around its `_ca_open`; close waits for it on
     `monitor_done` (bounded, 5 s); `_ca_open` starts nothing once `running` is false (destroys the
     IOProc, gives exclusive access back). A monitor only waiting to retry (up to 5 s) is NOT waited
     for: the agent SIGKILLs an engine not stopped in 3 s. Tests "close while the monitor opens leaves
     nothing running" (failed on the old code: "an IOProc is running after close (0 at return, 1
     after)") and "close does not wait for a monitor between retries" (anti-run against a close that
     waits for any monitor: 5002 ms). Carriers: `_ca_open`'s other callers are init (before any
     monitor) and `slimproto.c:720`, which runs on the main thread that later calls close; `running`
     goes false only in close.
  5. **The 100 ms off poll** — WRONG when measured, see `THE OFF POLL COSTS NOTHING MEASURABLE`.
  6. **status.json rewritten every 2 s** — CLEARED: it is the heartbeat. The menu's `agentAlive`
     is `updated` < 10 s old, and the file carries the device's live rate and format, so a
     write-on-change still needs a periodic write. No measured cost.
  7. **`rotate` "a log never grows without bound"** — the comment was the defect (rotation runs only
     when the agent or engine starts); comment FIXED. The engine holds engine.log open (append), so
     rotating it by rename mid-run would not bound it anyway.
  8. **`LMSDiscovery.find` blocks a cooperative-pool thread up to 2 s** — CLEARED: only while no
     server is known, one thread every ~6 s, and the pool has a thread per core; nothing else in the
     agent waits on it.
  9. **`menuLog` duplicates the agent's `Log`; menu.log never rotated** — CLEARED: menu.log gets one
     line per quit (86 bytes on Simon's Mac); the copy is ten lines.
  - Suite: engine output 21/21, swift 42 tests in 14 suites, install.sh 3/3; `swift build` (agent)
    and the engine build clean.
- **INLINE REVIEW AFTER 0.2.2 — 2026-10-10, CLOSED, NO code findings** (Simon: "check for any
  stale refs and bad documentation. then do another inline review"). Scope: the code changed since
  `REVIEW OF THE FIXES` (`apply_latest`/`apply_lock`, the retry cadence and `quiet`, `OutputFollow`
  and the agent's use of it, the "no server" throttle, `EngineArguments.modelName`) plus the docs.
  - **Stale refs, FIXED:**
    - the index named `followDeferred` and `pushVolume`, which no longer exist (now
      `OutputFollow`; `VolumePush` + `LatestValueSender`);
    - `tools/icon/make-icon` is a `.swift` source compiled into `build/tools/make-icon`;
    - INSTALL's examples said `LyrionPlay-0.1.0`, and nothing rewrites them at a bump, so they are
      now `<version>`;
    - §B said the GitHub repo was empty and Pages off; the API shows a README only, no releases,
      Pages on;
    - memory still listed Phase 5 as open.

    Added: README/INSTALL now name `scripts/test.sh`, INSTALL covers a DAC held by another app,
    and the Working rules carry "never prompt or offer to" commit. The check was mechanical: every
    backticked name and path in the docs grepped against the sources; misses were external (LMS,
    Apple, Material) or the parked design.
  - **Checked and CLEARED (do not re-derive):**
    - *`apply_latest` on a stale device ID:* `set_volume` copies `ca.dev`, then applies unlocked. A
      device replugged meanwhile has a new ID, but `apply_volume` returns at `find_volume`'s
      `v.n == 0` for a dead ID, BEFORE `watch_volume`, so the listener is never pointed at it.
      Lock order: `apply_latest` is entered with no lock held from all three callers;
      `_ca_open` unlocks before it.
    - *`_ca_open` from the slimproto thread and the monitor at once:* cannot happen. Only the IOProc
      raises `ca_reopen` (`ioproc`, the one writer), and the monitor runs only while nothing is
      open, so no IOProc runs.
    - *Retry log gating:* `_ca_open`'s `quiet` and the monitor's "retrying" line agree: tries 1-3
      and every 60th (5 minutes at 5 s). Suite: 4 reason lines, 3 "retrying" lines in ~70 tries.
    - *Hog re-taken on every retry:* a device that takes hog but then fails `_configure` (refuses
      a rate it listed, no 32-bit float, IOProc create/start fails) is hogged and released every
      ≤5 s, and macOS moves its default output away and back each time (`HOG MOVES THE DEFAULT
      OUTPUT`). NO WRITER: the FiiO, the DragonFly and the speakers never fail after the hog, and
      a DAC still relocking past 3 s heals on the next try. Re-raise only with a named device
      that fails this way.
    - *`scripts/test.sh` "on its own":* MEASURED. Both engine suites compile and link against an
      empty deps folder, so a fresh checkout runs the suite before any build.

- **REVIEW 2026-10-10 — /code-review of the whole repo (no git, so no diff), then Simon: "verify
  all then fix test fixes and that all carriers and callers are checked … We need a regression
  suite."** Every finding verified (measured where the HAL or ATS decides, else by the code path
  and the LMS 9.1 source), fixed, and pinned by a test that FAILED on the pre-fix copy (anti-run:
  engine suite 7 of 14 failed on the old `output_coreaudio.c`, exactly the 7 new tests; install
  suite failed on the old install.sh; the 7 pins passed on both).
  1. **Hog vs "Follow the macOS output"** (agent) — CONFIRMED, `HOG MOVES THE DEFAULT OUTPUT`.
     Fix `resolveDevice(in:holding:)`, `heldDevice`, `followDeferred`; status shows `engineDevice`;
     the Settings window resolves with `PlayerModel.heldDevice`. Tests `FollowSystem`.
     (`followDeferred` became PlayerCore's `OutputFollow` in `REVIEW OF THE FIXES`.)
  2. **`vrec.lock` held across Add/RemovePropertyListener** (engine) — CONFIRMED,
     `REMOVE WAITS FOR THE LISTENER`. Fix `vrec.watch` + `point_listeners` (old listeners removed,
     then the record, then `dev`/`ctl`, then the new ones); the listener ignores a device it is no
     longer on. Tests: "listener removed at exit…", "listener moved to a new device…".
  3. **Retry flood, hog kept after a failed open** (engine) — CONFIRMED in part: upstream
     `output_pa.c` also retries for ever (every 5 s), so the endless retry is inherited; ours was
     every 2 s and kept the DAC hogged after `set_rate` failed. Fix: `configure` gives exclusive
     access back on any failure (also `AudioDeviceStart`), `ca.open_failures` + `retry_wait`.
     The first cadence (2, 4, 8, 16, then 30 s) was itself a regression, see `REVIEW OF THE
     FIXES`: now 2, 4, then 5 s, the reason logged on tries 1-3 and every 60th. A missing device
     stays 2 s. Tests: "refused rate…", "busy device…" (two), control "missing device…".
  4. **Pushes out of order** (agent) — CONFIRMED by the code (a detached task per push, two HTTP
     calls each). Fix `LatestValueSender`. Tests `PushOrdering`, with a control showing the old
     pattern overlaps.
  5. **`mixer volume ?` before every push** — CONFIRMED, 27 ms median per push when LMS is idle.
     NOT replaced (it is the measured mechanism, `UNMUTE IS NOT A LEVEL`); only skipped when the
     engine's `<lms>` says LMS has a level, which cannot be a muted LMS (LMS sends gain 0 for
     volume <= 0, `Squeezebox2::volume`). Tests `VolumePushDecision`.
  6. **Mac volume reported to a fixed-volume player before the first audg** — CONFIRMED (the
     ledger's "nothing is reported while fixed" did not hold before the first track). The engine
     cannot know (no audg yet), and must keep reporting (`LMS SENDS VOLUME ON CONNECT` is wrong),
     so the AGENT asks `playerpref digitalVolumeControl ?` when `<lms>` is -1. Tests
     "reports carry…", `beforeAnyAudgAFixedPlayerGetsNothing`.
  7. **`volume_pending`** (engine) — CONFIRMED in code, but REACHABLE ONLY IN A RACE: the agent
     starts the engine only when the device is present and stops it within ~1 s of the device
     going, so "absent at init" is the probe-to-start window. Fixed anyway (pending set under the
     lock whenever no device is open with -V, claimed under the lock in `_ca_open`; a device that
     opens without a level to put on it is watched from its current level). Tests: "LMS level
     reaches a device absent at init", "device absent at init is watched once open".
  8. **ATS** — CONFIRMED, `ATS LOCAL IS PLAIN NAMES ONLY`. Test `TransportSecurity`.
  9. **install.sh menu race** — CONFIRMED by the code; the window is the `rm -rf`/`mv` after the
     kill, against the agent's 2 s tick. Fix: install.sh touches `menu-session-ending` before it
     looks for the menu (the agent already honours it for a minute; the new menu removes it).
     `MenuPresence.holdsOff` now holds the agent's half. Tests `test_install.sh` (the old script
     fails "marker at enumeration: no"), `MenuHoldOff`. `uninstall.sh` boots the agent out first,
     so it has no such race.
  10. **Picker v/h/m vs comment v/h/m/l/q; dead `PlayerIdentity.currentName`,
      `LaunchAgent.restart`** — CONFIRMED. No writer of l/q but a hand edit, so the comment is
      the defect: it now says the app offers v/h/m. Both helpers removed (no caller).
  - **Carriers checked:** every caller of `watch_volume`/`unwatch_volume` is unlocked (never under
    the output LOCK); lock order is `vrec.watch` → `vrec.lock`, the listener takes only the latter;
    the agent is the only reader of the report line (old 3-field lines parse as `<lms>` -1);
    `resolveDevice` callers are reconcile, writeStatus and the Settings window; nothing parses
    engine.log's changed "retrying" line; the marker's other writers/readers (menu at logout,
    agent and menu at start) are unchanged. One regression found in my own change and fixed:
    "no server is known" logged per report instead of per push, now at most every 5 s.
  - **Found on the way:** `build.sh` ignored test results (`swift test | grep … || true`), and
    `swift test` itself is flaky under CLT 27.0 (`TESTING MACROS BY NAME`). Both fixed in
    `scripts/test.sh`, which build.sh now runs and stops on.
- **REVIEW OF THE FIXES — 2026-10-10** (Simon: "lets do an inline review of latest code changes",
  then "yes given you made regression suite how did it miss these"). Three faults in my own
  `REVIEW 2026-10-10` code; each fixed and pinned by a test that FAILED on the pre-review engine
  (anti-run: exactly the 3 new engine tests failed: ended at the stale -30 dB; waits of 8, 16,
  30 s; the reason logged 55 times in 55 tries).
  1. **Stale level after a resume** (engine): `volume_pending` raised at every play from idle let
     the monitor's `_ca_open` apply a level while `set_volume` applied newer ones; LMS fades in on
     resume (`RESUME IS ONE AUDG`), so an older step could land last and stay until the next
     track. Fix `apply_latest`: one apply at a time under `apply_lock`, reading LMS's latest level
     inside (lock order `apply_lock` → output LOCK briefly → `vrec.watch` → `vrec.lock`; both
     callers take it unlocked). Test "a newer level wins over one being applied": the fake HAL's
     `during_next_level_change` hook lands a newer audg mid-apply.
  2. **Up to 30 s of silence after another app lets go** (engine): the backoff cured the log size
     by slowing pickup. Fix: retries 2, 4, then 5 s (upstream's cadence), `quiet` threaded into
     `hog`/`set_rate`/`configure` so a failure says why on tries 1-3 and every 60th
     (`RETRY_LOG_EVERY`). Tests "busy device plays within 5 s of being let go", "busy device says
     why at first, then every 5 minutes".
  3. **A follow lost on a restart** (agent): `stopEngine` cleared `followDeferred`, so after a
     restart on the held device an output chosen meanwhile was never followed. Fix `OutputFollow`
     (PlayerCore): only `resolve` changes it, the agent has nothing to clear. Tests
     `OutputFollowing`. Guarded by structure (no reset API), not by a test that runs the agent:
     a `follow = OutputFollow()` in main.swift would bring it back.
  - **Why the suite missed them, and what changed in how tests are written here:** (a) every
    engine test called the code on one thread, so no interleaving could happen; the fake HAL can
    now land an event inside a call. (b) The backoff test asserted the constants chosen, with time
    500x faster, so a 30 s wait passed as 60 ms; tests now assert the requirement (opens within one
    wait of at most 5 s; log lines counted). (c) The agent's state lived in the untestable
    executable; state that matters goes in PlayerCore. (d) The tests were written from the same
    reasoning as the fixes, so they confirmed the intent; a review of each fix round before it is
    called closed is what found these.
- **REGRESSION SUITE — 2026-10-10.** `sh scripts/test.sh` (also run by `build.sh`): engine
  conversion (2^24 values), engine output (16 tests: `output_coreaudio.c` compiled against a fake
  HAL with its clock, sleeps, stdout and threads redirected; each test in a forked child with a
  hang timeout; its header gives the command that builds it against an older copy, into another
  file, for an anti-run), swift (37 tests in 13 suites), install.sh (3 tests: sandboxed HOME and folder,
  shims for launchctl/open/lsof/ps/codesign/security/xattr, and it refuses to run if a shim would
  be bypassed). Each suite is judged by its summary line and its exit code. About 15 s.

- **PAGES LIKE THE FLEET — 2026-10-10.**
  - `tools/make_readme_html.py` is LMS-Listening-History's generator, in Lyrion green:
    - hero with the inline app glyph, the version badge from `VERSION`, and Download/Installation
      buttons;
    - feature cards from the README's Features table.
  - **Additions over the fleet's version:**
    - list items can wrap and hold code blocks and paragraphs; ordered lists keep one `<ol>`
      across blank lines;
    - content between the tagline and the first `##` renders as an intro, where the fleet
      generator dropped it;
    - links to INSTALL.md/README.md go to the pages, and other relative links go to GitHub.
  - `build.sh --release` regenerates the pages and ships INSTALL.html in the zip.
  - Checked: well-formed, 7 cards, one install list, rendered and viewed.
- **Phases 2-4: agent, menu bar app, build/sign/install — INSTALLED and switched on 2026-10-09.**
  - **Package:** `app/` (SwiftPM, Swift 5 language mode): `PlayerCore`, `Agent`, `App`.
  - **Tests:** 13 tests in 4 suites pass (`swift test`): probe parsing from the real `-l` output,
    argument building with controls, settings round-trip and defaults, MAC identity.
  - **`scripts/build.sh`:**
    - builds deps → engine (plus the conversion test) → Swift (plus tests), then the bundle;
    - signs inside-out by the identity's hash;
    - checks arm64, the `runtime` flag, zero entitlements and system-only libraries on all three
      executables;
    - `--install` copies to /Applications.
  - **Installed as Simon chose:**
    - "Mac Player", reusing the test identity `02:00:4c:4d:50:01`, which kept its LMS fixed volume;
    - the FiiO, with exclusive mode and DoP on.
  - **Measured:**
    - launchd runs the agent, the agent ran the engine with the expected arguments, and the
      engine connected;
    - status.json showed "Simons Music", connected;
    - LMS name "Mac Player", with the name file following;
    - `kill -9` of the engine: the agent restarted it;
    - `kill -9` of the agent: launchd restarted it;
    - switching off (bootout) stopped the engine cleanly;
    - the rebuild needed no new Local Network approval.

- **Phase 1 audible verification on Simon's FiiO M11 Plus — PASS 2026-10-09.**
  - **The DAC, as `-l` reports it:** UID `AppleUSBAudioEngine:FiiO:FiiO M11 Plus:3fa90f5:1`;
    rates 32k-384k; physical format 32-bit integer only; NO Mac-side volume control (its knob).
    Simon chose LMS "fixed at 100%" plus the FiiO knob, and DoP on.
  - **The command:** engine with `-o <FiiO UID> -a 0:1 -D -R vE -Z 384000 -C 30`; test player MAC
    `02:00:4c:4d:50:01`, `digitalVolumeControl=0`.
  - **Rates.** FLAC at 44.1/16, 48/24, 88.2/24, 96/24 and 192/24: the FiiO's nominal rate equalled
    the track's every time, in 32-bit integer format, hogged by the engine PID. Each rate switch
    was confirmed in 10 ms, and nothing was resampled ("rates match").
  - **Bit-exact.** `tools/bitcheck` on the tap against Apple's ExtAudioFile decode of the file from
    `/music/<id>/download`: 0 of 10,534,070 samples differed across the five tracks, about 11 s each.
  - **Anti-test.** At `digitalVolumeControl=1`, volume 99: 618,869 of 623,344 samples differ, so
    DIFFERENT, as it must be.
  - **DoP.** DSD64 went as DoP at 176.4 kHz, and Simon saw the FiiO show DSD; a DoP lock proves the
    HAL-to-DAC hop is untouched.
  - **DSD256 and DSD512** went as PCM, as designed: "DSD sample rate too high for device -
    converting to PCM", resampled 1411200 / 2822400 → 352800. See `DSD256 IS PCM ON THE FIIO`.
  - **Replay gain.** With `replayGainMode=1`, a track tagged −6.41 dB logged `replay_gain: 31232`,
    which is LMS's own `dBToFixed` (10^(−6.41/20) × 256 = 122.4 → 122 << 8). Exact 16.16 would be
    31331; LMS quantises to 1/256 before sending.
  - **Idle release.** With `-C 30`, the FiiO stayed hogged at 26 s after stop and was released
    (owner −1) at 31 s. Also released on engine exit.
  - **Listening.** Simon, on headphones: every clip played and sounded good.
- **Phase 1 build — 2026-10-09.**
  - `deps/build-deps.sh` produced 13 static arm64 libraries:
    - FLAC 1.5.0, Ogg 1.3.6, Vorbis 1.3.7, Opus 1.6.1 (all via CMake);
    - opusfile 0.12, compiled directly because its release archive has no CMakeLists.txt;
    - mpg123 1.33.7, faad2 2.11.4, soxr 0.1.3, Apple ALAC.
  - `make -f Makefile.coreaudio` builds `engine/squeezelite`: arm64. `otool -L` shows libSystem,
    CoreAudio, CoreFoundation and libc++ only. Build options `OSX COREAUDIO SELFPIPE RESAMPLE
    ALAC OPUS DSD NO_MAD LINKALL`.
  - Exhaustive conversion test (`make -f Makefile.coreaudio test`): 16,777,216 values, 0
    failed; the anti-test value rounded. PASS.
- **Verification step 1, the engine alone — PASS 2026-10-09.**
  - `-l` lists the FiiO and the built-in speakers (44.1-96k, float only, main volume
    -63.5..0 dB with mute) as JSON.
  - A silent connect (`-C 5`, so no device was opened) appeared in LMS `players` as model
    `squeezelite`, modelname `LyrionPlay`, firmware 2.0.0-1609, connected.
  - HELO: `MaxSampleRate=384000,dsf,dff,alc,aac,ogg,ops,ogf,flc,aif,pcm,mp3`. Test MAC
    `02:00:4c:4d:50:01`, name "LyrionPlay (test)".
- **Phase 0 gate 1, signing identity — PASS 2026-10-09.**
  - Simon did not know how to make the certificate, so it was created from the command line:
    LibreSSL key + self-signed certificate (`extendedKeyUsage = codeSigning`, 10 years),
    imported to the login keychain with `-T /usr/bin/codesign`.
  - It showed as `CSSMERR_TP_NOT_TRUSTED`, which is expected and harmless.
  - A test binary signed with the hardened runtime and no prompt; its designated requirement
    named the certificate leaf.
  - That identity was deleted on 2026-10-09 when the project moved to `EACH USER SIGNS IT`.
- **Phase 0 gate 2, agent plus network — PASS via Fallback 1, 2026-10-09.**
  - SMAppService failed after a rebuild (`SMAPPSERVICE PINS THE FIRST BUILD`).
  - A classic launch agent then ran the BSD-socket child (TCP `plex:3483` plus the discovery
    broadcast) and its own URLSession request to `plex:9000`, all PASS, including the first run
    after a rebuild that changed the child's code hash.
  - Simon approved two Local Network prompts (agent, child).
  - The test agent was stopped and its plist and log folder removed; findings are in §A3.
  - The spike source was deleted on 2026-10-09.
- **Phase 0 gate 4, first half, CMake — PASS 2026-10-09.** CMake 4.4.4 built from source by
  `deps/build-cmake.sh`; `lipo -archs` prints `arm64`.
- **Phase 0 gate 3, `swift test` under the Command Line Tools — PASS 2026-10-09.**
  - Swift Testing ran (library version 2084, arm64e-apple-macos14.0).
  - A deliberately failing test was reported and the run exited 1, so suites are trustworthy
    by summary line plus exit code. No Xcode needed.

### D. ADDING TO THIS LEDGER
When a finding is declined, accepted, parked or disproven, add it in the same session: the entry
in its section and its index row, with the reason as a fact that can be disproven.
