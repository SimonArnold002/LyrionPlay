# Review Ledger §C: CLOSED FINDINGS

Moved verbatim from CLAUDE.md.


Each entry records that a defect, as described, was fixed. It does not cover the code written to
fix it (see HOW TO LOG).

- **CODE-REVIEW 2026-10-15 (8) — /code-review of a893561 (0.4.13; `origin/dev` 7faf2f8..HEAD plus the
  tree, which changed only this file), ALL 5 VERIFIED + FIXED 2026-10-16, INSTALLED as 0.4.14
  2026-10-15 23:21Z, committed d36bc27 to dev (unpushed, Simon: "commit")** (Simon: "lets do another /code-review lyrionplay", then "verify and fix all, test
  them all and please no more regressions, review the code base properly before making changes").
  Gates: none of the five in the index, §A2, §A3 or §C. Round (7)'s finding 3 CLOSED only its live
  test; the retry this round adds was never there (0.4.0 dropped it), so finding 1 is new. Numbered
  as shown to Simon (the review's own order was 1, 3, 4, 2, 5). Baseline suite PASS before any
  change (engine output 70, name 43, swift 108, install.sh 3).
  **Method:** the agent findings were run on the real agent binary in a sandbox (§A3 `CFFIXED_USER_HOME
  SANDBOXES THE AGENT`): a fake engine (two fake USB DACs for `-l`, logs every probe and start, exits 1
  on demand, else sleeps), server 127.0.0.1:1. Nothing reached the installed player, a device or
  LMS. Every scenario ran on a893561's own binary (kept before any edit) and on the new one.
  1. **A player whose files cannot be made was never tried again** — VERIFIED (old binary:
     `players/` chmod 555, the player listed with "Could not create this player's files"; chmod 755:
     still not started 40 s later, 1 probe in 24 s). 0.3.14 `exit(1)`ed on it ("cannot create the
     player identity") and launchd's KeepAlive restarted the agent. FIXED: `scheduleIdentityRetry`
     (`identityRetry`, `identityBackoff`): one `reconcile("retry")` waiting while `identityProblems`
     has a player, 1 s doubling to 30 s as `scheduleRestart`; cancelled and back to 1 s when none.
     agent.log "created the identity of <name>" when it works; the failure still logged once. New
     binary: retries at 1, 3, 7, 15, 31 s (probes 3 -> 5 over 20 s); started 7 s after the folder
     became writable (the next retry), "retry: starting the engine of …". Controls, same on both
     builds: switched off while failing, no retry in 35 s (probes 4 -> 4); a healthy engine of
     another player NOT restarted by 5 retries (1 start); a plain start unchanged.
     **Side effect, MEASURED, ACCEPTED by Simon 2026-10-16** (§A2 `A RETRY STARTS A WAITING ENGINE`: "side
     affect accepted will look it if it ever comes up in real world use"): a retry is a whole reconcile, so like
     a device or settings change it starts at once another player's engine waiting out its restart
     backoff. With both failures beginning together the two backoffs ran in step (DAC 2 started at
     0 1 3 7 15 32 s on both builds). With the identity problem beginning while DAC 2 waited 30 s:
     old 0 1 3 7 16 32 36 67, new 0 1 3 7 16 32 36 37 39 43 51 68: 4 more starts in ~15 s, then in
     step once per 30 s. Only while two failures overlap; the engine exits at once either way.
     Avoiding it needs a case in `reconcile` for the retry; the comment on `scheduleIdentityRetry`
     says it (my first comment claimed "up to twice per 30 s", WRONG, corrected from the measurement).
  2. **The menu lost a player's device while its engine was down** — VERIFIED (old: `deviceName` null
     for each second of a restart backoff). 0.3.14 showed `engineDevice ?? settings.resolveDevice(in:)`.
     FIXED: `PlayerSlot.plannedDevice` (each reconcile's `plan[key]?.device`), shown by `writeStatus`
     while `slot.device` is nil; `exclusive` stays false (no engine PID) and there is no DoP rate
     (`slot.format` nil). New: "Fake DAC" throughout the backoff. Carriers: `heldDevice` and
     `syncFixedVolume` keep `slot.device`; the app's `heldFollowDevice` needs `exclusive`, false with no
     engine; Remove's wait reads only whether the player is listed. Control, same on both builds:
     unplugged -> no device line and "Not connected"; plugged back -> running.
  3. **"Connecting to <server>…" for a player with no identity** — VERIFIED from the code (`StatusRows`
     read only `connected`, false). FIXED: `PlayerStatus.serverLine(serverName:)`, moved from the app's
     `StatusRows` with its three strings unchanged, is nil when `mac` is nil; the view then shows no
     server line, and the problem line says why. Suite: `aPlayerWithNoIdentityHasNoServerLine` pins
     the three strings (control) and the nil; mutant (the guard removed) failed it, 3 issues. Not seen
     on screen: the menu app is not run in a sandbox (§A3, it boots out the real agent).
  4. **A failed `fork()` counted as a passed test, in the name and output runners** — VERIFIED by an
     anti-run: under `ulimit -S -u 1` the OLD name suite printed "43 tests, 43 passed / result: PASS",
     the output suite "70 tests, 70 passed", both exit 0, nothing run. FIXED: `waited = pid > 0 &&
     waitpid(pid, …) == pid`, so a test not waited for fails, with "(not run: fork: <strerror>)"; the
     old messages unchanged for the old cases. Same run: "0 passed / result: FAIL", exit 1, no scratch
     folder left; normal runs 43/43 and 70/70. Mutant (`pid > 0` dropped): "43 passed / PASS" again,
     because `waitpid(-1)` returns -1, the failed pid, so the guard is the part doing the work.
  5. **"No identity" was an empty-string MAC** — VERIFIED (`LMSClient.call` sends `[player, command]`,
     and "" is LMS's server-level form; old status.json `"mac": ""`). FIXED: `PlayerStatus.mac` is
     `String?`, nil there and not written; suite `aPlayerWithNoIdentityIsWrittenWithNoMAC` (no "mac"
     key, a MAC still written, round trip). Readers: none use a status's `mac` (as round 7 found).
     Transient: a 0.4.13 menu reading a new agent's status.json with such a player fails to decode it
     ("Starting…") until the install replaces both.
  Suite PASS after (engine output 70, name 43, swift 110, install.sh 3); the rebuilt test binaries are
  tracked, as before. **INSTALLED as 0.4.14** (Simon: "build and install"; "Yes, 0.4.14" to version
  up, `bump-version.sh patch`, INSTALL.html and README.html regenerated): `build.sh --install`, suite
  PASS inside it; install.sh "installed: /Applications/LyrionPlay.app, version 0.4.14 (was 0.4.13)";
  nothing was playing on either LyrionPlay player (LMS `players`, read before). agent.log "agent
  started: LyrionPlay 0.4.14 (202610160020)", the DragonFly's and Follow's engines on their old MACs
  (b6:4e:cb:e9:16:34, 96:57:54:14:bd:87), "LMS: using Simons Music (plex:9000)"; status.json lists
  both with their MAC and device, connected, no problem. Owed live: nothing audible; 2 can be seen
  only in a restart backoff, 1 and 3 need a player whose files cannot be written (round 7: not made
  on the rig).

- **CODE-REVIEW 2026-10-15 (7) — /code-review of 8371589 (0.4.12; `origin/dev` 7faf2f8..HEAD, tree
  clean), 1 and 2 DECLINED, 3-8 VERIFIED + FIXED 2026-10-15, INSTALLED as 0.4.13 2026-10-15 22:15Z,
  committed to dev (unpushed, Simon: "build install and commit")** (Simon: "lets do
  another /code-review lyrionplay", then "verify the rest", "fix the 7 issues": the six left after 1
  and 2). Gates: nothing in the index or the rounds for any of the eight. Baseline suite PASS (engine
  name 43, swift 108) before any change.
  1. **Two LMS on one host, different slimproto ports, judged as one server** — DECLINED by Simon (§A2
     `TWO LMS ON ONE HOST`). The code claim was true (`ask_server_uuid(slimproto_ip, PORT)` asks UDP
     3483; the connect uses `slimproto_port`).
  2. **Follow's built-in fallback takes the first built-in output** — DECLINED by Simon (§A2 `FOLLOW'S
     BUILT-IN FALLBACK`).
  3. **A player that is on but has no identity was left out of status.json** — VERIFIED: `makeSlot`
     throws only when its folder or MAC file cannot be written (a full disk, `players/` unwritable, a
     file in the way); `reconcile` skipped the slot and `writeStatus` skipped the player, so the menu
     said "No player is on" (or left that player out), the cause only in agent.log, logged again at
     every reconcile. FIXED: `identityProblems` (by player: set in `makeSlot`'s catch, cleared on
     success and for players no longer on); `writeStatus` lists such a player with `mac` "" and the
     problem "Could not create this player's files: <reason>"; the log line only when the reason
     changes. Carriers checked: every reader of `status.players` (the menu, `status?.player(follow)`'s
     `exclusive`, Remove's wait for the player to leave: a removed player is not on, so not listed); no
     reader uses a status's `mac`. Not covered by a suite (agent main); compiled; not reproduced live.
  4. **INSTALL.md: "A device that is unplugged keeps its row and its settings"** — VERIFIED against
     `PlayerList.rows` (§A2 `AN UNPLUGGED DEVICE WITH NO SAVED SETTINGS`): only a device with an entry
     in settings.json, i.e. switched on or changed and saved. FIXED: the sentence says so; INSTALL.html
     regenerated (README.html and index.html unchanged).
  5. **`Paths.slug`: "two keys never share a folder or a log"** — VERIFIED: the DragonFly's UID
     (`…AudioQuest DragonFly Black v1.5:AQDFBL0100009556:1`) is cut at `…AudioQuest-Dragon`, before its
     serial, so two units of one model differ only in the 4 hex digits (1 in 65,536).
     **THE SLUG IS NEVER WIDENED**: the review's fix (`%08x`, all 32 bits) renames every device player's folder,
     which holds its MAC, so each DAC would come back as a new LMS player and settings from 0.4.0 on
     must carry over. FIXED: the comment states the odds and the rule; PlayerCoreTests
     `eachPlayerHasItsOwnFiles` pins the rig's real folder names (DragonFly `…-Dragon-ea39`, FiiO
     `…-3fa90f5-1-2a05`). Mutants: `%08x` failed the pins and the old regex (the old test already
     caught a wider hash; my claim that it would not was WRONG); a changed FNV seed failed ONLY the new
     pins.
  6. **UPSTREAM.md's 5(a) "New files (ours)" left out `tests/test_slimproto_name.c`** — VERIFIED (named
     only in passing at the `load_player_name` split). FIXED: listed, with why a merge of the name code
     must update it (it `#include`s `slimproto.c`).
  7. **`chooseVolume` told a wanted answer from a stale one by comparing the caption** — VERIFIED, and
     the comment was not the contract: Fixed, another mode, Fixed again set the same caption, so the
     first read's answer passed the guard ("chosen again … not wanted" claimed otherwise). Harmless
     today (both read the same LMS volume). FIXED: `HeldNote` (`.reading(UUID)` per read, `.note(text)`),
     `heldNote: [String: HeldNote]`; an answer is taken only while its own read is shown, and the
     `.fixed` guard stays. Every reset of `heldNote` (reload, revert, Remove, a new choice) still drops
     a read in flight, now structurally. Readers: Save's error and the cog's caption use `.text`. Not
     covered by a suite (app UI); compiled.
  8. **The name suite's scratch folder left by a test that crashes or times out** — VERIFIED by an
     anti-run: the 500 ms test's child killed mid-test (SIGKILL to the child of the PID launched, own
     TMPDIR) left 1 folder; the claimed build-up was NOT there (0 `lyrionplay-name-*` in $TMPDIR after
     rounds (3)-(6)'s mutant sweeps). FIXED: `make_dir` in the parent before the fork, `remove_dir`
     after `waitpid`, `setup` (socket pair) in the child; the same kill, three times: 0 left.
  Suite PASS after (engine name 43, swift 108, all 5 suites); the rebuilt test binary is tracked, as
  before. INSTALLED as 0.4.13 (build.sh --install, suite PASS inside): agent.log "agent started:
  LyrionPlay 0.4.13 (202610152314)", the DragonFly's and Follow's engines on their old MACs
  (b6:4e:cb:e9:16:34, 96:57:54:14:bd:87: the slug, so each folder, unchanged), "LMS: using Simons
  Music". **7 VERIFIED LIVE 2026-10-15** (Simon, on 0.4.13: the DragonFly's cog, Fixed, another
  mode, Fixed again, not saved): the caption read "holds LMS volume 13 (-54.7 dB)", LMS's own `mixer
  volume ?` for b6:4e:cb:e9:16:34 = 13 (player stopped), so the read still lands under `HeldNote` (the
  failure the finding warned of was a guard that never matches, leaving Fixed unsaveable). Not
  observable live: that the first read's answer was dropped (both reads return 13 within ms); that
  rests on the code. **3 CLOSED without a live test, Simon 2026-10-15** ("we cant test for what we
  cant create so that is closed until it comes up as a problem from a user"): its writer (a full disk,
  an unwritable `players/`) is not made on the rig; not an owed check, re-open only on a user's report.
  ROUND CLOSED.

- **CODE-REVIEW 2026-10-15 (6) — /code-review of 481dfa4 (0.4.11; `origin/dev` 7faf2f8..HEAD, tree
  clean), 1-7 and 9 VERIFIED + FIXED 2026-10-15, 8 DISPROVEN, committed bb5a583 to dev (unpushed, Simon: "commit"), INSTALLED as 0.4.12 2026-10-15 20:47Z** (Simon: "lets
  do another /code-review of lyrionplay", then "yes look to fix these although i am reluctant to
  change 5 i have not heard this and the audio side works very well I dont want to head down more work
  fixing more regressions if you can make it work first go with none then go for it"). Gates: nothing
  in the index; the ledger hits (rounds (3)/(5), `THE DEVICE STAYS WHERE THE MAC PUT IT`) cover the
  fixes, not this behaviour; 2, 3 and 6 are about round (5)'s own code. Each finding read in the code
  and reproduced by a test (or measured) before any change:
  1. **A long LMS name stored cut inside a character** — VERIFIED: `strncpy(player_name, …, 64)` kept
     64 bytes, `fgets(…, 64, …)` reads 63 back, and `PlayerIdentity.name(at:)` reads strict UTF-8, so a
     cut character gave no name (the cog fell back to settings.json's, the menu kept the old one), and
     the cut was offered to other servers. Writer: a user renaming a player in LMS to a long accented
     name (LMS is the only renamer; `fitName` caps only the names LyrionPlay makes). FIXED: `fit_name`,
     63 bytes of whole characters (as `fitName`), on a name LMS sends and on the file read at start; a
     file 0.4.8-0.4.11 cut is rewritten at LMS's next name (it differs). LMS keeps its full name: the
     confirmation sends LMS's own `setd` text back, as upstream. The Swift reader is unchanged.
  2. **"A power cut leaves the old file whole" with a plain `fsync`** — VERIFIED (on a Mac `fsync` does
     not flush the drive's cache; `fcntl(F_FULLFSYNC)` does). FIXED: `flush_to_disk` (`F_FULLFSYNC`,
     `fsync` where a file system lacks it) before the rename, so after a power cut the file is the old
     one or the new one, whole. The rename itself can still be lost (the old name kept, rewritten by
     LMS's next name); no directory sync, as nothing claims the newest name survives. MEASURED (scratch
     probe, 20 writes each, internal SSD): a name write 0.54 ms with `fsync`, 3.91 ms (worst 4.61) with
     `F_FULLFSYNC`; paid only on a change (7).
  3. **A server stamped after an offer that was never written** — VERIFIED (`send_packet` was `void` and
     only logged "failed writing to socket"); round (5)'s own code. FIXED: `send_packet`/`sendSETDName`
     return whether every byte was written (upstream's other callers ignore it, UPSTREAM.md), and
     `process_setd` stamps only then. RESIDUAL, stated: bytes the kernel took, then the connection lost
     before LMS read them (within about a round trip: <1 ms on the LAN): stamped without the offer, so
     the next connect's empty answer takes that LMS's name (a new LMS: its default). Not reachable by
     the suite; no such drop seen. ACCEPTED by Simon the same day (§A2 `AN OFFER LOST IN FLIGHT`).
  4. **A new player's `-n` offer never stamped when LMS already had it** — VERIFIED by test (481dfa4:
     the second connect with a held rename loops, in one run and across a restart). Writers: the first
     name write failed (full disk), or the connection dropped after LMS took `-n` and before its answer
     came. FIXED: `name_offered` for every offer written in full: `name_from_lms`, the name file and the
     stamp, as for LMS's answer. TRADE, stated: 3's residual now reaches a new player's first connect too
     (an offer lost after the kernel took it, to a new LMS: its default name at the next connect, where
     before `-n` was offered again); both need the connection lost within a round trip, and the loop it
     removes is the worse outcome. ACCEPTED by Simon ("i am fine to accept that compromise make sure it
     isnt raised again"): §A2 `AN OFFER LOST IN FLIGHT`, never a finding.
  5. **`put_lms_level` read `now` before `lv.lock`** — VERIFIED by a deterministic test: a one-shot hook
     in the suite's clock (`during_next_clock_read`, the test's thread only) lands the Mac's next move
     between the read and the lock; on 481dfa4 LMS's answer pulled the drag back to -30.10 dB with 2
     writes. FIXED: the time is read under the lock. Why nothing else changes: `lv_reported` is the one
     writer of a report's time and stamps under the lock, `CLOCK_UPTIME_RAW` is monotonic, so no report
     is newer than `now`; every rule and number is as before, the read ~ns later. Simon had not heard it
     and was reluctant; done on his condition ("if you can make it work first go"): one line, its test,
     and the output suite and matrix unchanged (70/70, 25,690 scenarios 0 failed). Not live-tested.
  6. **The failed-write test's FAILED lines lost** — VERIFIED (a forced failing check, stdout to a file
     as `scripts/test.sh` does: 481dfa4's test printed only ✘, this one the FAILED line). FIXED:
     `limit_file_size`, lifted before every check; the stamp's own failing write still exercised (the
     name stored first, then an offer under the limit; round (5)'s mutant "the stamp written in place"
     needs it).
  7. **The name file and stamp rewritten unchanged at every connect** — VERIFIED (inode test). FIXED:
     `file_holds`; "storing name in" now only for a change.
  8. **`refresh()` assigning unchanged values every 1.5 s** — DISPROVEN, measured (§A3 `AN EQUAL
     ASSIGNMENT NOTIFIES NO ONE`). No change.
  9. **`writeStatus` kept a stale `slot.name`** — VERIFIED (a file that reads as none kept the old name
     there, settings.json's in `playerName`). FIXED: `writeStatus` uses `playerName`. The app's
     `lmsName` stays its own (it reads into the observed `lmsNames`, round (3) finding 8): the same rule,
     file else settings.json. Not covered by a suite (agent main).
  - **Tests:** engine name 33 -> 43: an offer that was not sent stamps nothing; a new player's offer
    that was not sent names nothing (control: passes on 481dfa4 too); a new player whose `-n` LMS
    already has is named by its offer, and across a restart; `fit_name`'s table (2-, 3-, 4-byte
    characters at the cut); a long name stored to its last whole character; a cut file mended; a whole
    64-byte file read to its last whole character; a name and stamp held are not written again (inodes);
    a name written reaches the disk (`F_FULLFSYNC` counted through the suite's `fcntl`). 9 of the 10 FAIL
    on 481dfa4's slimproto.c (`NAME_SOURCE`), the 33 earlier pass on both. Engine output 69 -> 70:
    "LMS's answer during a drag is not put on" (FAILS on 481dfa4's output_coreaudio.c, `OCA_SOURCE`).
    MUTANTS, 9 of 9 killed: the send result ignored, the `-n` offer not named (round (5)'s rule), the
    name always written, the stamp always written, `fsync` only, no cut at a `setd`, no cut at the load
    (it SURVIVED until the whole-64-byte-file test was added), the cut at 64, a partial character kept.
  - **Carriers:** `send_packet`'s other callers (HELO, STAT, RESP, META, IR) ignore the result, as
    before; the name file's readers (the engine at start, `PlayerIdentity.name` for the app and the
    agent) see the same format (no newline), now never cut inside a character; the stamp's only reader
    is slimproto.c; `.tmp` files as before; logs: "set name" as before, "storing name in" only on a
    change, "unable to store new name in" on a failed write; `set_volume`'s path: only the place of
    `put_lms_level`'s clock read. The agent's `slot.name` readers (logs, `VolumeChange.player`, the menu's
    `PlayerStatus.name`) get the same name but where the file reads as none.
  - **After:** `scripts/test.sh` PASS (engine conversion; engine output 70/70 with the matrix, 25,690
    scenarios; engine name 43/43; swift 108 in 22 suites; install.sh 3/3); `swift build` of every target,
    the one known warning (main.swift:544); the engine builds with no warning in slimproto.c or
    output_coreaudio.c. Live checks owed after a build Simon asks for: a connect gives ONE "set name" and
    no "storing name in"; an LMS rename stores once; a new device player's first connect writes its name
    file at the offer. Nothing to hear for 5.
  - **INSTALLED as 0.4.12 2026-10-15 20:47Z** (Simon: "build and install", "Yes, 0.4.12"; simonsMac the
    only LyrionPlay player connected, stopped, volume 47, 13 tracks). `bump-version.sh patch`; `build.sh
    --install`, suite PASS inside it; install.sh "version 0.4.12 (was 0.4.11)", "stopped the old player".
    agent.log "agent started: LyrionPlay 0.4.12 (202610152146)", Follow on the MacBook Pro Speakers,
    "LMS: using Simons Music (plex:9000)". **Finding 7 VERIFIED LIVE:** engine-follow.log 21:47:27 local
    "retrieved name simonsMac", connected, plex's UUID, ONE "set name: simonsMac" and NO "storing name in"
    (0.4.11's connect at 20:13:04 wrote both); `players/follow/name` and `name.server` keep their 20:13
    times (not rewritten), the same 3 stamp lines, no `.tmp`. LMS after: simonsMac connected, stopped,
    volume 47, 13 tracks. **Both owed checks VERIFIED LIVE 2026-10-15** (Simon: "both tested"): an LMS
    rename of Follow to "simonsMac2" at 21:50:33 local gave ONE "set name" and ONE "storing name in",
    the name file rewritten, `name.server` kept (20:13: unchanged); a NEW DragonFly player (MAC
    b6:4e:cb:e9:16:34, `-n` "prodmac46 AudioQuest DragonFly Black v1.5") wrote its name file AT THE
    OFFER (21:52:18.035, `name_offered`), 48 ms before LMS's answer ("set name" 18.083), which wrote
    nothing more; its stamp "192.168.1.234 2c913d97-…"; LMS lists both connected under those names.
    Nothing to hear for 5. Seen on the way, NOT this round: "unable to connect to server 0" at each
    engine start, then connected 5 s later (upstream's retry); 0.4.11's start had it too (20:12:59),
    645 such lines in engine-follow.log's history.

- **CODE-REVIEW 2026-10-15 (5) — /code-review of a0e6c7f and the tree (`origin/dev` 7faf2f8..HEAD;
  rounds (1)-(4) had covered up to cd56290), ALL 8 VERIFIED + FIXED 2026-10-15, INSTALLED as 0.4.11** (Simon:
  "lets do another /code review of lyrionplay", then "verify these and look to fix, test fixes and
  check for regrressions we are gping round in loops for simple setitings"). Dropped at the gates:
  the tracked test binaries, the UUID-ask residuals (`UUID ASK RESIDUALS`), a server judged by its
  address without a UUID. Each finding read in the code first; the engine ones reproduced by a test
  before any change:
  1. **A server offered a name it already has was never stamped** — VERIFIED, LMS 9.1 source:
     `playerSettingsFrame` sets the pref (Squeezebox2.pm:1032), and `Prefs::Base::set` returns at
     once when the value is unchanged (Base.pm:95), so no `setd` came back and `add_name_server`
     never ran. That broke the stamp's invariant (every server the player was connected to is in it):
     a rename held on that server, then a reconnect, offered the name across it: the loop. Writers:
     plex at an address whose UUID reply was lost (stamp has the LAN line, the Tailscale connect gets
     no UUID: offered `simonsMac`, equal, unstamped); the same name set by hand on two LMS; a line
     dropped past 8 or by finding 2. FIXED: `process_setd` stamps the server when it offers the
     player's name (`name_from_lms` only; a new player's `-n` offer is stamped by LMS's answer, as
     before). Why that is right: after an offer LMS's pref IS that name, whether or not it answers.
  2. **The stamp was read only when the name file held a name** — VERIFIED by test: an empty name file
     next to `[A, B]`, `-n` offered to A, A's answer rewrote the stamp as `[A]`. FIXED:
     `load_player_name` reads the stamp whatever the name file holds.
  3. **The name file was written in place** — VERIFIED for a full disk (test, `RLIMIT_FSIZE`: the file
     left EMPTY, so the next start offers `-n` over LMS's name), WRONG for the review's own cause, a
     stop mid-write (§A3 `A STOP CANNOT CUT THE NAME WRITE`). FIXED with 4: `store_name` and
     `store_name_servers` write `<file>.tmp`, check `fflush`/`ferror`/`fsync`/`fclose`, then
     `rename()`; any failure removes the `.tmp` and keeps the old file (`open_replacement`,
     `replace_file`). The stamp is written the same way: an empty stamp reads as none. [The power cut
     was NOT covered: a plain `fsync` on a Mac leaves the data in the drive's cache. `F_FULLFSYNC` since
     CODE-REVIEW 2026-10-15 (6) finding 2.]
  4. **A failed name write still rewrote the stamp** — VERIFIED (same test: the stamp left empty too).
     FIXED: the stamp is written only after `store_name` succeeds.
  5. **No test of an unstamped server already holding the name** — FIXED, the suite 28 -> 33 tests: a
     server offered a name it already has is stamped (in-run reconnect with a held rename), the same
     across a restart, an empty name file keeps every server, a write that fails keeps the name and
     the stamp (name write and stamp write), a name stored leaves no `.tmp`. The 4 behaviour tests
     FAIL on a0e6c7f's slimproto.c (`NAME_SOURCE` anti-run: 29 of 33), the 28 earlier pass on both.
     MUTANTS, 6 of 6 killed: no stamp at the offer (2 fail), stamped in memory only (2), the stamp
     read only with a name (1), the name written in place (1), write errors ignored (1), the stamp
     written in place (1; it SURVIVED until the failed-write test also offered the name).
  6. **Round (4)'s §C heading said "not live-tested"** after every check was done — FIXED (prose).
  7. **§A2 said the suite has 22 tests** — FIXED (33).
  8. **`makeSlot` read `playerName` up to three times** — VERIFIED; no writer for the values to differ
     (the slot's engine is not running yet), so a cleanup: read once after the adopt, the adopt log
     line still after the adopt (round (4) finding 5). Agent main has no suite; builds.
  - Carriers: the stamp has no reader outside slimproto.c (`Paths` only names it); the `.tmp` files sit
    in `players/<slug>/`, which the agent lists only by folder (`stopOrphanedEngines`) and Remove
    deletes whole; the log line "storing name in" kept (now after the write). On the rig every server
    in use is already stamped, so nothing changes at the next connect.
  - After: `scripts/test.sh` PASS (engine conversion; engine output 69/69; engine name 33/33; swift
    108 in 22 suites; install.sh 3/3); `swift build` of every target, the one known warning
    (main.swift:544); the engine builds with no warning in slimproto.c.
  - **INSTALLED as 0.4.11 2026-10-15 19:12Z** (Simon: "build install commit", "Yes, 0.4.11"; simonsMac
    the only LyrionPlay player connected, stopped, volume 47, 13 tracks). `bump-version.sh patch`;
    `build.sh --install`, suite PASS inside it; install.sh "version 0.4.11 (was 0.4.10)", "stopped the
    old player". agent.log "agent started: LyrionPlay 0.4.11 (202610152011)", Follow on the MacBook Pro
    Speakers, "LMS: using Simons Music (plex:9000)". engine-follow.log: connected to 192.168.1.234, UUID
    plex's in 4 ms, ONE "set name: simonsMac", "storing name in" (the new write path); `players/follow/`
    holds no `.tmp`; `name.server` the same 3 lines. LMS after: simonsMac connected, stopped, volume 47,
    13 tracks. Not live-tested: an offer to a server already holding the name (no such server on the
    rig: every one in use is stamped); no sound test needed for it.

- **CODE-REVIEW 2026-10-15 (4) — /code-review of the 9 unpushed commits (`origin/dev..HEAD`, cd56290
  the only code no round had covered), FIXED, INSTALLED as 0.4.10 2026-10-15 (build 202610151723),
  every live check VERIFIED 2026-10-15 (below)** (Simon: "lets do a /code-review of lyrionplayer", then "verify and fix", then
  "build it install it and commit"). Before the install the Server setting was put back from
  192.168.1.119 (the round (3) test) to `plex` in settings.json (Simon chose it; only that line
  changed), with the player off, so this build's first connect stamps plex. Six findings, each read in the code first:
  1. **The stamp held only the last server that named the player** — VERIFIED (code + LMS 9.1 source):
     `process_setd` overwrote it at every name, while LMS keeps a disconnected player and its pending
     `setd` for 300 s (`Slimproto.pm` `$forget_disconnected_time`). So: named by A, renamed in A while
     playing, moved to B (B names it, restamps B), back on A within 300 s: A is offered the old name
     while its held rename goes out, which is `TWO NAMES IN FLIGHT LOOP`. Writer: the Server setting
     changed and back, or LMS's `serv` switch, with a rename made while playing. FIXED: `<file>.server`
     is a list, one line per server (§A2 `LMS OWNS THE PLAYER NAME`), at most 8, the naming server moved
     last (`add_name_server`); `named_by_this_server` asks every line (`is_connected_server`). The format
     changed freely: the one-server stamp was never built.
  2. **One lost UUID reply blanked the stamp's UUID** — VERIFIED (`strcpy(name_server_uuid,
     server_uuid)` with `server_uuid` ""). FIXED in `add_name_server`: the line at this address whose
     UUID does not differ is the server's; a connect without a UUID keeps the line's. Another LMS at an
     old address (UUIDs differ) gets its own line, the old one kept.
  3. **The window's own probe on the main thread** — CLEARED, measured: 0.06-0.07 s (§A3 `THE SETTINGS
     WINDOW'S PROBE FREEZES IT`).
  4. **`PlayerSlot.restartWanted` dead since bb4b0d0** — VERIFIED (only reset and read). FIXED: the
     field, its reset in `startEngine` and the ternary in `reconcile` removed.
  5. **The 0.3.x adopt log line named settings.json's name** — VERIFIED (`makeSlot` read `playerName`
     before `adoptOldPlayer` copied 0.3.x's name file). FIXED: the name is read after the adopt, for the
     log line and the slot.
  6. **`ask_server_uuid`'s 500 ms and its source-address check** — DECLINED by Simon ("lets accept it
     as it is and reject that finding"; §A2 `UUID ASK RESIDUALS`): both end with the address deciding,
     as for a server that does not answer; LMS's UDP socket answers from the route's address
     (UDP.pm:37), no such LMS seen. Accepting a reply from any address was offered and declined.
  - **Suite `engine name`** 22 -> 28 tests: a rename held by a server the player left and came back
    to (in one run, and across an engine restart on the other server), a lost UUID answer keeps the
    stamp's, a UUID joins its address's line, a new LMS at an old address is added with the old kept,
    the stamp bounded at 8 with a renaming server moved last; the line format asserted. MUTANTS, 5 of 5
    killed: the last server only (= the old rule, 7 fail, both held-rename tests loop), the UUID not
    kept (1), the line found by address alone (1), no move-last (1), only the last line asked (3).
  - After: `scripts/test.sh` PASS (engine conversion; engine output 69/69; engine name 28/28; swift
    108 in 22 suites; install.sh 3/3); `swift build` of every target, the one known warning
    (main.swift:543); the engine builds with no warning in slimproto.c. Not covered by a suite: 4, 5
    (agent main). Installed with round (3)'s fixes, the first build to carry them; live-tested below.
    **First connect VERIFIED LIVE 2026-10-15 17:25 local** (Simon: "installed"; engine-follow.log):
    "retrieved name SqueezeLiteMac" (the bug's, no stamp), connecting to 100.71.35.108 (plex over
    Tailscale, Simon away), "server uuid: 2c913d97-…" 41 ms later, ONE "set name: simonsMac", stored;
    `players/follow/name.server` = "100.71.35.108 2c913d97-fd70-4828-aa63-736619393939"; LMS `players`
    shows 96:57:54:14:bd:87 "simonsMac", connected. The DragonFly too, switched on in Settings 17:32:20
    (Simon: "dragonfly connected"): its name file (unstamped, LMS's name) kept, UUID in 26 ms, ONE
    "set name: prodmac46 AudioQuest DragonFly Black v1.5", stamp = the same Tailscale line; LMS shows it
    connected under that name; the agent's start line names it by LMS's name. **The held rename
    across a restart VERIFIED LIVE 2026-10-15** (Simon: "that did it"): the DragonFly renamed
    "Dragonfly" in LMS while playing (nothing reached the player: LMS holds it until a STOP, a pause is
    not one, StreamingController `isStopped`), LyrionPlay quit and reopened 17:34:54 while it played:
    the reconnect sent NO `set name` (no loop, the 0.4.7 case), LMS kept "Dragonfly", playback
    carried on. Simon cleared the queue (Material has no Stop button: clearing the queue IS the stop)
    and at 17:38:32 ONE "set name: Dragonfly" arrived, the name file took it, stamp unchanged.
    **Follow on 192.168.1.119 VERIFIED LIVE 2026-10-15 19:47 local** (Simon: "playername stayed and is
    in LMS on 192.168.1.119"): .119 answered UUID c79e183d-5614-40b3-8601-d9b330933ba7 in 8 ms, was
    OFFERED "simonsMac" (not in the stamp), took it: ONE "set name: simonsMac"; `name.server` now two
    lines, plex's Tailscale line KEPT (the round (4) list) + "192.168.1.119 c79e183d-…". NOT yet the
    LAN UUID: back home `plex` resolves to 192.168.1.234 (en0), but the running engine resolved the
    hostname once at its start (upstream: `slimproto_ip` is kept across reconnects), so its 19:39
    reconnect was still to 100.71.35.108. **Back to plex at home VERIFIED LIVE 2026-10-15 19:49 local**
    (Simon: "connects to plex fine"): the restarted engine resolved `plex` to 192.168.1.234, connected,
    UUID 2c913d97-… (plex's) 4 ms later, ONE "set name: simonsMac"; `name.server` now three lines,
    the LAN one "192.168.1.234 2c913d97-…" added beside the Tailscale one (one LMS at two addresses,
    both kept); LMS shows simonsMac connected. **Every live check of rounds (3) and (4) done.**

- **CODE-REVIEW 2026-10-15 (3) — /code-review of 0.4.7-0.4.9 (bb4b0d0, the only code no round had
  covered), FIXED, committed cd56290, INSTALLED as 0.4.10 with round (4), VERIFIED LIVE 2026-10-15**
  (Simon: "lets do a /code-review lyrionplay"; on finding 1, "squeezelitemac",
  "i am right just tested it", then "as long as we dont go down the same path and have issues with saving
  and the loop.fix, verify the rest and fix those"). Eight findings, each read in the code first:
  1. **A server that never saw the player renamed it to LMS's default** — CONFIRMED LIVE by Simon: Server
     set to 192.168.1.119 (another LMS), engine-follow.log 08:14:29 "retrieved name simonsMac", 08:14:30
     "set name: SqueezeLiteMac", the name file overwritten. LMS 9.1: the empty answer makes LMS send its
     pref (`playerSettingsFrame`, Squeezebox2.pm:1016-1029); for a client it has never seen that pref is
     `_makeDefaultName` (Client.pm:479), the model name, numbered when taken, so every LyrionPlay player.
     FIXED: the stamp (§A2 `LMS OWNS THE PLAYER NAME`, "Only to the server that named it"), keyed on the
     server's UUID where it answers ("One LMS at two addresses — BUILT"); the name
     reading moved into `load_player_name` for the suite (UPSTREAM.md). Simon's Follow file still says
     "SqueezeLiteMac" from the test, with no stamp: back on plex FIRST (0.4.9 or this build alike) the
     empty answer has plex send "simonsMac" again and stamps plex. If this build first runs on .119, .119
     stamps "SqueezeLiteMac", and the next connect to plex OFFERS it, renaming the plex player (the rule
     working as designed on a name the bug wrote).
     **Suite `engine name`** (`tests/test_slimproto_name.c`, slimproto.c #included, the rest stubbed, its
     packets read off a socket pair): 22 tests (9 for the UUID: plex's measured reply parsed, the request
     against a stand-in LMS on 127.0.0.1, one LMS at two addresses, a new LMS at an old one, a held rename
     across an address change, and its CONTROL without the UUID: the loop; 8 more mutants, all killed), among them the rig's loop case (a rename held by the
     server that named it), the upgrade case (no stamp, a held rename), a new server keeping the name, a
     `serv` switch, and a CONTROL that the model loops when the name crosses a held rename. MUTANTS, 6 of
     6 killed: 0.4.9's rule (5 fail), upstream's (9 fail, both held-rename tests loop), no stamp read as
     another server (3), no stamp written (4), the server not kept in memory (2), the stamp not read (4).
  2. **A device plugged in within ~10 s of Off was missed** — VERIFIED: `devicesChanged` and the copy of
     status.json's devices in `refresh` trusted `agentAlive` (status under 10 s old) alone. FIXED:
     `agentReportsDevices` = `isOn && agentAlive` for both (LaunchAgent.isOn is the plist, gone at Off).
     `agentAlive`'s other readers (menu, `heldFollowDevice`, `statusServer`, `removePlayer`) unchanged.
  3. **The device probe ran on the main thread with Settings closed** — VERIFIED (`DeviceCaps.probe` waits
     for `squeezelite -l`; the watcher lived for the app's life). FIXED: `settingsOpen` (set in the
     window's `onAppear`/`onDisappear`) gates `devicesChanged`, whose probe now runs on a detached task;
     the window's own probe when it opens is unchanged.
  4. **settings.json's name where LMS's was due** — VERIFIED at three places: the cog header of an
     unplugged device, Save's "Fixed has no level to hold", the agent's Follow log line. FIXED:
     `lmsName(row)` in the app; agent `playerName(_:)` (the name file, else settings.json's), which
     `makeSlot` uses too.
  5. **`removePlayer`'s 10 s wait** — CLEARED (§A3 `A REMOVE TIMES OUT ONLY ON A WEDGED AGENT`).
  6. **The name file's comments said only the engine writes it** — VERIFIED (`adoptOldPlayer` copies
     0.3.x's). FIXED, prose: `PlayerIdentity.name`, `Paths.playerName`, §A2.
  7. **`playerStates` repeated `listing(of:in:)` and read `connected` another way** — VERIFIED; latent
     (JSON numbers arrive as NSNumber, which both reads agree on). FIXED: `playerStates` calls `listing`.
  8. **Every name file read every 1.5 s** — VERIFIED; FIXED with 3: `refresh` reads them only while
     Settings is open, and once more as it opens.
  - After: `scripts/test.sh` PASS (engine conversion; engine output 69/69; engine name 13/13; swift 108
    in 22 suites; install.sh 3/3; engine name 22/22 after the UUID); `swift build` of every target, the one known warning; the engine
    builds with no warning. Not covered by a suite: 2, 3, 4, 8 (app UI / agent main). Not built, not
    installed, not live-tested. Live check owed: Follow on 192.168.1.119 renamed in that LMS or, after a
    connect to plex restores "simonsMac" and stamps plex, back on .119 offered "simonsMac"; a held rename
    on plex then a restart: one `set name` line. [All VERIFIED LIVE on 0.4.10 2026-10-15: §C
    `CODE-REVIEW 2026-10-15 (4)`.]

- **LMS OWNS THE PLAYER NAME — BUILT 2026-10-15, INSTALLED as 0.4.8, committed bb4b0d0, VERIFIED LIVE** (Simon: "the name saved in the app
  changed the player name in LMS on restart it did not go the other way", then "LMS name before restart
  was just AudioQuest and on previous build that did not sync to the app so you had two different
  names", then the decision, §A2). Found live on 0.4.7: `TWO NAMES IN FLIGHT LOOP` (§A3) ran on the
  DragonFly for 8 min 40 s after the install's reconnect; LMS and its file ended at "AudioQuest".
  - **Built:** engine `slimproto.c` (`name_from_lms`, the empty answer, an empty `-N` file falls back to
    `-n`), `main.c` (`-n` with `-N`), UPSTREAM.md; `EngineArguments` passes `-n`; removed:
    `Settings.renames`, `withCurrentNames`, `PlayerIdentity.createNameFile`/`writeName`/
    `restartsForRename`, `PlayerState.name`, the agent's rename restart, the app's Name field, its
    rename save and blank-name check; added `PlayerModel.lmsName`; the agent's `slot.name` and the
    menu read the name file. INSTALL.md says to rename in LMS.
  - **Carriers:** the name file: read by the engine (`-N` at start), `PlayerIdentity.name` (app rows,
    cog, menu, agent log); written by the engine only (and `adoptOldPlayer`'s copy of 0.3.x's, missing
    only). `-n`: settings.json's name, which nothing changes once saved (no Name field), so engine
    arguments stay stable. `fitName` still fits the defaults (the only names given).
  - **Tests:** `lmsOwnsThePlayerName` (name file read rules; `-n`/`-N` in the arguments; an LMS rename
    leaves the arguments unchanged), `eachPlayerHasItsOwnIdentity` with `-n`; the rename tests removed
    with their API. `scripts/test.sh` PASS; the full engine builds with no warning. The engine's name
    logic is NOT covered by a suite (slimproto.c is not linked into it) [since CODE-REVIEW 2026-10-15 (3) it is:
    `engine/tests/test_slimproto_name.c`]: live check owed after a build,
    with Simon: rename a player in LMS while it plays, restart LyrionPlay before it stops; one `set
    name` line, LMS's name kept, the menu and the cog show it. [VERIFIED LIVE on 0.4.10 2026-10-15:
    no `set name` at the reconnect, ONE at the stop; §C `CODE-REVIEW 2026-10-15 (4)`.]

- **LMS RENAMES SHOW IN SETTINGS — SUPERSEDED the same day by `LMS OWNS THE PLAYER NAME`; BUILT 2026-10-15, INSTALLED as 0.4.7 00:20Z (uncommitted), not
  live-tested** (agent.log "agent started: LyrionPlay 0.4.7 (202610150119)"; both players connected,
  menu names = LMS names) (Simon: "build and install"; earlier,
  to "the Name field could show the name the player actually has in LMS … Want me to do that?": "yes
  players can be renamed via LMS Player settings or via the app"). Found on the rig the same day:
  0.4.5's lost rename left the DragonFly's settings.json and name file apart, and 0.4.6 showed
  settings.json's name, so the mismatch could not be seen or repaired by a Save. Now
  `PlayerModel.reload` shows `Settings.withCurrentNames()` (the name files); Save compares typed
  names with those; the agent skips the restart when connected LMS already has the new name
  (`restartsForRename(_:at:lmsName:)`, `PlayerState.name` from the `players` loop); the menu reads the
  name file. Rule in §A2 `THE NAME FILE HAS TWO WRITERS`. Test `aRenameInLMSShowsInSettingsAndStays`;
  MUTANTS: LMS's name ignored, the file not checked, `withCurrentNames` a no-op, an empty file read
  as a name (killed after an empty-file case was added): all 4 fail. `scripts/test.sh` PASS (swift
  104 in 21 suites); `swift build` the one known warning. Not live-tested.

- **CODE-REVIEW 2026-10-15 (2) — /code-review of the CODE-REVIEW 2026-10-15 fixes (uncommitted tree),
  ALL 7 VERIFIED + FIXED, INSTALLED as 0.4.6 2026-10-15 00:09Z** (Simon: "commit and build and install and we can check"; commit 73735a1 on dev; agent.log "agent started: LyrionPlay 0.4.6 (202610150108)", both players connected) (Simon: "lets do another /code-review of lyrionPLay", then "The
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
    `renameReached` (now `restartsForRename`). settings.json: written by the app's Save, the agent's missing-file save and
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
    call; the listener takes `vrec.lock` briefly, then `lv.lock` alone. [`put_lms_level` read its time
    BEFORE `lv.lock` until CODE-REVIEW 2026-10-15 (6) finding 5: a report stamped in between made
    `now - at` wrap and the answer was put on; now read under it.] The agent, PlayerCore and the
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

