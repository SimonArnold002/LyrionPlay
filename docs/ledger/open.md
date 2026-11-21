# Review Ledger §B: KNOWN-OPEN AND ACCEPTED — do not re-report as new

Moved verbatim from CLAUDE.md.


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
  the same restart follows, so only the writer changed. A rename saved while OFF: VERIFIED LIVE on
  0.4.6, below. Still UNVERIFIED: an LMS rename kept across a later Save.
- **A rename saved while OFF reaches LMS: VERIFIED LIVE on 0.4.6, 2026-10-15** (Simon: "confirmed it
  works"). DragonFly switched off (agent.log 00:10:37Z "stopping the engine … switched off"), renamed
  "AudioQuest DragonFly" and saved: its name file written 00:10:57Z by the app's Save while no engine
  ran; switched on, agent.log 00:12:07Z "starting the engine of AudioQuest DragonFly"; settings.json,
  the name file and LMS (82:6a:8f:3d:06:01, over HTTP) all "AudioQuest DragonFly".
- **A rename saved while OFF does not reach LMS on 0.4.5: CONFIRMED LIVE 2026-10-15** (Simon: "I just
  edited Dragnfly whilst off then turned it on name in LMS has not changed but it has in the app"),
  as CODE-REVIEW 2026-10-14 #2 said. settings.json "AudioQuest DragonFly Black v1.5" (saved 01:06:22
  local), `players/AppleUSBAudioEngine-AudioQuest-AudioQuest-Dragon-ea39/name` still "prodmac46
  AudioQuest DragonFly Black v1.5" (Oct 12), agent.log 00:06:23Z started its engine with that file, LMS
  (82:6a:8f:3d:06:01) shows the old name. The tree's fix (Save writes the file) is not built. GAP in
  the tree: a mismatch left by 0.4.x is not repaired by the new build (Save writes only a Name typed
  after the window opened, and the window shows settings.json's name), so this DAC needs its name
  typed again, or the window must show the name file's name. Simon typed it again (VERIFIED LIVE,
  below), then said yes to the window showing it (§C `LMS RENAMES SHOW IN SETTINGS`, INSTALLED as 0.4.7).
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

