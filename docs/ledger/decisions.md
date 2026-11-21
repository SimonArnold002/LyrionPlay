# Review Ledger §A2: NOT FINDINGS — LyrionPlay decisions

Moved verbatim from CLAUDE.md.


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
    - **0.4.6 / 0.4.7 / 0.4.8** (2026-10-15): 0.4.6 = CODE-REVIEW 2026-10-15 (2) (commit 73735a1); 0.4.7 = LMS
      renames shown in Settings (uncommitted; its install's reconnect set off `TWO NAMES IN FLIGHT LOOP` on
      the DragonFly, ended when Simon switched the player Off at 00:29:20Z); **0.4.8** (Simon: "build and
      install") = `LMS OWNS THE PLAYER NAME` (engine + app) and `REMOVE A PLAYER`. INSTALLED ~00:50Z: suite
      PASS inside build.sh, install.sh "version 0.4.8 (was 0.4.7)", the new menu app running. The player was
      OFF before (no launch agent plist) and stays off until Simon switches it on: no agent or engine of
      0.4.8 has run yet.
    - **0.4.11** (Simon: "build install commit", "Yes, 0.4.11", 2026-10-15): `CODE-REVIEW 2026-10-15 (5)`.
      INSTALLED 19:12Z, suite PASS inside build.sh; details in §C.
    - **0.4.12** (Simon: "build and install", "Yes, 0.4.12", 2026-10-15): `CODE-REVIEW 2026-10-15 (6)`
      (commit bb5a583). INSTALLED 20:47Z, suite PASS inside build.sh; details in §C.
    - **0.4.13** (Simon: "build install and commit", "Yes, 0.4.13", 2026-10-15): `CODE-REVIEW 2026-10-15
      (7)`. INSTALLED 22:15Z (202610152314), suite PASS inside build.sh; the agent restarted on it and
      used Simons Music, each player on its old MAC (the slug unchanged); details in §C.
    - **0.4.14** (2026-10-16): `CODE-REVIEW 2026-10-15 (8)`, installed (§C). **FIRST RELEASE: merged to
      `main` 2026-10-16** (Simon: "commit and push to dev then merge to main"), a fast-forward of `dev`
      (main held only the initial README), tagged `v0.4.14`. With it, written at the merge as the fleet
      does: CHANGELOG.md (created, one 0.4.14 entry), README.md brought up to 0.4.x (*One player, or
      one per device*, the screenshots in `docs/images/`, shown by `tools/make_readme_html.py`'s
      `<img>` rule). The GitHub release page and its two zips (`build.sh --release`) are Simon's step:
      no `gh` here. The forum post (BBCode) was written the same day, not kept in the repo.
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
  renames a player: LyrionPlay writes no name file at all (`LMS OWNS THE PLAYER NAME`). The
  Settings window shows the defaults for an unreadable file and says so; its Save keeps the file as
  settings-unreadable.json first (`Settings.save`). Settings from before 0.4: not migrated (`ONE PLAYER PER DAC`); never report
  their set-aside as a defect.
- **LMS OWNS THE PLAYER NAME — DECIDED by Simon 2026-10-15, BUILT the same day, INSTALLED as 0.4.8, committed bb4b0d0; VERIFIED LIVE (an LMS rename while connected on 0.4.8; a rename held while playing, across a restart, on 0.4.10)**
  (Simon, after 0.4.7's name loop: "I think remove renaming as an option in the app and leave it to LMS
  to do this and it syncs. Only time our app creates a name is when a device is added as we do already.
  Being able to save it in both locations is adding more probelems to code round"). Supersedes `THE NAME
  FILE HAS TWO WRITERS` below.
  - **The app renames nothing.** The cog shows *Name* read-only ("Rename this player in LMS, in its
    player settings."), the player row and Follow's subtitle show it: `PlayerModel.lmsName`, the name
    file, else settings.json's. Never put into the draft: saved, it would change `-n` and restart the
    engine. settings.json's `name` is only the name a NEW player offers (the defaults, `fitName`d).
  - **Nothing in the app or the agent writes the name file** but `adoptOldPlayer`'s one-time copy of
    0.3.x's (Follow, missing only); the engine does, with every name LMS sends
    (upstream `process_setd`). The agent passes `-n <settings name> -N <file>` (`EngineArguments`; both
    together only in this fork, main.c). The menu and agent.log read the file (`writeStatus`, `makeSlot`).
  - **The engine leaves the name to LMS** (`slimproto.c`, `name_from_lms`): once the `-N` file held a
    name at start, or LMS set one, it answers LMS's name query (at every connect) with an EMPTY name,
    and LMS sends its own (`playerSettingsFrame`: an empty value -> `setPlayerSetting(pref)`). A new
    player (no file, or an empty one) answers with `-n` once; LMS takes it and sends it back, which
    writes the file. Since CODE-REVIEW 2026-10-15 (6) the offer itself, once written in full
    (`sendSETDName` true), names the player: `name_offered` sets `name_from_lms`, writes the file and
    stamps the server, as LMS's answer does (an offer equal to LMS's name gets none). A name is kept
    to 63 bytes of whole UTF-8 characters (`fit_name`, as `fitName`), and the file and stamp are
    written only when their text changes (`file_holds`), flushed with `F_FULLFSYNC`: "storing name
    in" appears only for a change, so a connect's normal engine log is ONE "set name" line alone. So an LMS rename made while the player was disconnected, or queued while it played,
    reaches the player at the next connect instead of being overwritten by the player's old name, and
    two names can no longer chase each other (`TWO NAMES IN FLIGHT LOOP`, §A3).
  - **Only to the server that named it** (since CODE-REVIEW 2026-10-15 (3), Simon tested it: a new LMS at
    192.168.1.119 named Follow "SqueezeLiteMac" over "simonsMac", engine-follow.log 08:14:30). The engine
    keeps the servers that have named it beside the `-N` file, `<file>.server` (since CODE-REVIEW
    2026-10-15 (4): one line per server, oldest first, its IPv4 address then a space and its LMS
    `server_uuid` when it answered; at most 8; `add_name_server` moves the naming server's line last,
    keeping the line's UUID when this connect got none; written after the name file by
    `store_name_servers`, read at start by `load_name_servers` in `load_player_name`. Before (4) it
    held only the LAST server, `store_name_server`/`load_name_server`, never built). The empty answer
    goes only to those servers (`named_by_this_server`, `is_connected_server`), or when there
    is no stamp (a name file from 0.4.8-0.4.9, 0.3.x's adopted one: as 0.4.9, until the next name LMS
    sends stamps it); any other server, a `serv` switch included, is offered the name, as upstream, and
    takes it (LMS's `playerSettingsFrame`: a value that differs sets the pref). Why that is loop-safe:
    the loop needs a rename LMS HELD for this player, and only a server the player was connected to can
    hold one, and every such server named it or was offered the name (since CODE-REVIEW 2026-10-15
    (5) an offer stamps the server too: an offer equal to LMS's name gets no answer; since (6) only an
    offer written in full, a new player's `-n` offer included), so it is in the
    stamp. Not only the last one: LMS 9.1
    keeps a disconnected player, its pending `setd` with it, for 300 s (`Slimproto.pm`
    `$forget_disconnected_time`, `slimproto_close` -> `forget_disconnected_client`), so a rename held
    on A survives a trip to B and back (CODE-REVIEW 2026-10-15 (4) finding 1). **One LMS at two addresses — BUILT 2026-10-15** (Simon
    first: "a user issue to solve … if LMS only offers ip and not mac"; then, told LMS has a UUID,
    "measure it", "build it"). Slimproto carries NO server identity (LMS 9.1 source: server -> player
    frames strm/cont/codc/aude/audg/setd/serv/vers; `vers` is the version string; the HELO's MAC/UUID are
    the player's; the server's MAC is sent nowhere). LMS's stable `server_uuid` is in its discovery reply
    for the `UUID` TLV (Discovery.pm:124; UDP port fixed at 3483, UDP.pm `SERVERPORT`) and in JSON
    `serverstatus`. So `ask_server_uuid` sends LMS's discovery request (`eUUID`) by UDP to the connected
    server's own address after the TCP connect and before the HELO (LMS asks for the name after the
    HELO); two tries of 250 ms, then no UUID (`parse_server_uuid` reads the `E` TLV answer). The stamp
    holds the address and the UUID; `named_by_this_server`: both UUIDs known, they decide (Simon's
    hostname, LAN at home and Tailscale away, is one server; a new LMS at an old address is another);
    else the address. Residual: a server that does not answer UDP is judged by its address. So is
    one whose reply comes from ANOTHER address of its host: `ask_server_uuid` takes a reply only from
    the address it asked, and LMS 9.1's UDP socket is bound to `$main::localClientNetAddr` (UDP.pm:37;
    all addresses unless `--playeraddr`), so the reply's source is the one the host's route picks
    (a secondary alias or a second NIC on the same subnet answers from the primary). Same outcome as
    no answer, no new failure; no such LMS seen. DECLINED by Simon 2026-10-15 (CODE-REVIEW 2026-10-15
    (4) finding 6, "lets accept it as it is and reject that finding"; a reply from any address was
    offered and declined), `UUID ASK RESIDUALS`. The cost without an answer, ~500 ms before the HELO at each connect, is measured
    below (503 ms).
    MEASURED 2026-10-15 (Mac on another network, 192.168.47.200): the request with NAME, UUID, VERS, JSON
    tags straight to plex:3483 answered from 100.71.35.108 (Tailscale) in 11-26 ms: NAME "Simons Music",
    UUID 2c913d97-fd70-4828-aa63-736619393939, VERS 9.1.2, JSON 9000; `plex` resolves by MagicDNS to that
    address (`plex.taildebbf.ts.net`). The engine's own `ask_server_uuid` after the build: 23 ms with the
    UUID over Tailscale; "" after 503 ms at the unreachable LAN address (in use never asked: only after
    a TCP connect). At home MEASURED 2026-10-15 19:49 local (0.4.10): `plex` resolves to 192.168.1.234
    (en0), which answers the UUID request in 4 ms with plex's UUID. The engine resolves the hostname
    only at its start (upstream keeps `slimproto_ip` across reconnects): coming home with it running,
    it stays on the Tailscale address until it restarts.
    (My first note said "not on the rig, the Server setting is a literal IP": WRONG, the IP seen was
    Simon's .119 test; he uses a hostname.) Each server owns its own name for the player: renamed
    on one, the other offers or keeps its own. Suite `engine/tests/test_slimproto_name.c` (43 tests
    since CODE-REVIEW 2026-10-15 (6), with a model of LMS's side that reproduces the loop).
  - Never re-add a Name field, a rename path in the app, or an agent that writes names.

- **AN OFFER LOST IN FLIGHT — ACCEPTED by Simon 2026-10-15, NOT A FINDING** ("i am fine to accept that
  compromise make sure it isnt raised again"). Symbols: `name_offered`, `sendSETDName`/`send_packet`'s
  result, `process_setd`'s offer, the stamp (`add_name_server`, `store_name_servers`) and `name_from_lms`
  set at an offer, a new player's `-n` offer naming it. The rule (CODE-REVIEW 2026-10-15 (6) findings 3
  and 4): a name offer the engine wrote in full names the player on that server (stamp, name file,
  `name_from_lms`), since LMS's pref is that name then and an equal offer gets no answer. The residual:
  the kernel takes the offer's bytes, then the connection is lost before LMS reads them, which needs a
  drop within about one round trip of the offer (<1 ms on the LAN, tens of ms over Tailscale). The
  server is then stamped without having the name, so the next connect's empty answer takes LMS's own
  name: on a brand-new LMS its default (SqueezeLiteMac, numbered), where before round (6) a new player
  offered `-n` again. Visible, and a rename in LMS mends it. Accepted because it replaces the rename
  loop (`TWO NAMES IN FLIGHT LOOP`), the worse outcome, which needed a drop in an equally short window.
  Do NOT report it, in any form (a stamp "without confirmation", an offer "assumed received", a new
  player "named before LMS answers"), and do not propose a confirmation for it (a timer after the offer,
  a second empty answer, waiting for LMS's `setd`, the socket's send queue). Re-raise only with the
  drop seen live: an engine log with an offer, the connection lost within a second, then LMS's default
  name at the next connect.

- **A RETRY STARTS A WAITING ENGINE — ACCEPTED by Simon 2026-10-16, NOT A FINDING** ("side affect
  accepted will look it if it ever comes up in real world use"). Symbols: `scheduleIdentityRetry`,
  `identityRetry`/`identityBackoff`, `reconcile("retry")`, `scheduleRestart`/`restartWork`/`backoff`,
  `EnginePlan.changes`. The behaviour (CODE-REVIEW 2026-10-15 (8) finding 1, MEASURED in the sandbox):
  a retry for a player whose files cannot be made is a whole reconcile, so, as a device or settings
  change does, it starts at once another player's engine that is waiting out its restart backoff. Only
  while the two failures overlap: begun together the backoffs run in step (no extra start); begun
  while the other engine waits 30 s, 4 more starts in ~15 s, then in step once per 30 s. That engine
  exits at once either way; nothing is heard. Do NOT report it in any form (the retry "restarting
  other players", "defeating the backoff", "doubling the restart rate"), and do not propose a case
  in `reconcile` to skip a slot with `restartWork` pending. Re-raise only from real use: a user's
  agent.log with an engine started at the retries while another player's files could not be made,
  and a harm beyond the log lines.

- **REMOVE A PLAYER — BUILT 2026-10-15 at Simon's request, INSTALLED as 0.4.8, committed bb4b0d0; a connected device's remove VERIFIED LIVE (below)** (Simon:
  "we also need a way to remove devices from the app/agent so we can add them fresh again if need be.
  Currently if I no longer owned one of the devices its stuck forever. This should remove it from LMS as
  well of possible"). *Remove This Player…* at the foot of a device player's cog (never *Follow the macOS
  output*), with a confirmation; it acts at once, not at Save, and keeps the window's other edits
  (`PlayerModel.removePlayer`). In order, because a running engine reconnects:
  1. its entry out of settings.json on disk and out of `settings`/`draft` (`Settings.removing`); an
     unreadable settings.json refuses the remove;
  2. wait (up to 10 s, status every 0.5 s) until the agent no longer lists the player (its tick saw it
     off and stopped the engine); still listed: nothing more is removed, and the window says so;
  3. its files: `players/<slug>/` (MAC, name file, engine.pid) and `engine-<slug>.log` + `.1`
     (`Paths.files(of:)`);
  4. LMS, at the server status.json last named (also while the player is off): `LMSClient.forget` waits
     up to 5 s for LMS to show it disconnected, sends `<mac> client forget`, and checks `players`.
  The Settings window says the outcome (`removeNote`): removed from LyrionPlay and LMS; LMS not known,
  not answering, or still showing it: forget the player in LMS. LMS facts (9.1 source,
  `clientForgetCommand`): forget is IGNORED, silently, while the player is connected; it removes the
  player from LMS's list as LMS's own Forget does; LMS keeps its prefs under the MAC, never used again
  (a device back after a remove gets a new MAC, so a new LMS player with the default name). A device
  still connected is listed again at once, off, with the defaults. Tests: suite `RemovingAPlayer`
  (LMS stubbed through `URLProtocol`: forget only once disconnected, never while connected, a refused
  forget said, nothing sent when not listed or no answer; the settings, Follow kept, the files). MUTANTS,
  5 of 5 killed (no wait for the disconnect, forget not checked, not-listed forgotten, Follow removable,
  the older log kept). Live check owed: remove a disconnected DAC (gone from the list and from LMS), and
  a connected one (back as new, off; switched on, a new LMS player).
  - **LIVE on 0.4.8, 2026-10-15** (Simon: "replugging back in has not seen it"): the DragonFly removed
    (settings entry and `players/AppleUSBAudioEngine-AudioQuest-AudioQuest-Dragon-ea39/` gone, so the
    remove's steps 1 and 3 worked), then replugged: `squeezelite -l` listed it, the Settings list did not.
    NOT the remove: with the player OFF (no agent since 00:29:20Z) the app took devices only from its
    probe when the Settings window OPENED, and `refresh` read status.json's devices whenever the player
    was switched on, even from an agent that had stopped. Older than 0.4.8. FIXED in tree, not built:
    `PlayerModel` runs `AudioDeviceWatcher` and probes 1 s after a device change while no agent is alive
    (`devicesChanged`); `refresh` takes status.json's devices only from a live agent (`agentAlive`). Not
    covered by a suite (app UI). Simon then switched the player on (00:49:34Z, "my mistake": it was off):
    agent.log "agent started: LyrionPlay 0.4.8", the engine with `-n simonsMac -N …/follow/name`;
    engine-follow.log "retrieved name simonsMac", then ONE "set name: simonsMac" 5 s later (LMS sending
    its own name after the empty answer: `LMS OWNS THE PLAYER NAME` at a connect, as designed); LMS lists
    simonsMac only, the DragonFly's old player 82:6a:8f:3d:06:01 gone (forgotten by the remove, or
    dropped as disconnected: not told apart); status.json lists the DragonFly, so the Settings list shows it.
  - **VERIFIED LIVE on 0.4.8, 2026-10-15** (Simon: "changed name in LMS it synced to agent"): the removed
    DragonFly switched on came back as a NEW player: new MAC 62:7e:9f:0a:57:38, offering its `-n` default,
    engine log 01:51:00 local "set name: prodmac46 AudioQuest DragonFly Black v1.5" (LMS took it and sent it
    back). Renamed in LMS while connected: 01:51:46 "set name: AudioQuest DragonFly", ONE line; its name
    file, the menu (status.json) and LMS all "AudioQuest DragonFly". So a remove gives a fresh player, and
    an LMS rename reaches LyrionPlay (`LMS OWNS THE PLAYER NAME`). Then owed, VERIFIED LIVE on 0.4.10
    2026-10-15 (§C `CODE-REVIEW 2026-10-15 (4)`): an LMS rename while PLAYING, then a restart before it
    stops (the loop's case). Still owed here: removing an unplugged DAC.
  - **BUG found live the same minute** (Simon: "but not in the app"): the Settings window kept the old
    name. `PlayerModel.lmsName` read the name file in the view, which SwiftUI cannot observe, so no redraw
    followed an LMS rename until the window reopened. FIXED in tree, not built: `PlayerModel.lmsNames`,
    read at every 1.5 s `refresh` for Follow, every saved player and every listed device, assigned only
    when it changed; `lmsName` reads it; a remove drops its entry. Not covered by a suite (app UI).
    **INSTALLED as 0.4.9** (with the device re-probe while off; Simon: "build and install"): suite PASS
    inside build.sh, install.sh "the player is unchanged: it keeps running", "version 0.4.9 (was 0.4.8)";
    menu app only (agent and engine of 0.4.8 kept running). **VERIFIED LIVE 2026-10-15** (Simon: "okay
    works"); committed to dev with 0.4.7-0.4.9, unpushed.
  - **AN UNPLUGGED DEVICE WITH NO SAVED SETTINGS LEAVES THE LIST — BY DESIGN, Simon 2026-10-15** ("okay
    just not seen that before and makes sense"; he saw the DragonFly, removed at 00:58:30Z, vanish when
    unplugged). `PlayerList.rows` keeps a device that is not connected only when settings.json has an entry
    for it (FiiO, Melomania: "Not connected"); a removed or never-set-up device is listed only while it is
    plugged in, which is what lets a removed DAC go for good. The menu bar panel lists only players that
    are on. Not a finding.

- **THE NAME FILE HAS TWO WRITERS — SUPERSEDED 2026-10-15 by `LMS OWNS THE PLAYER NAME`** (kept for the
  record; INSTALLED as 0.4.6/0.4.7). DECIDED 2026-10-15 (my design, on Simon's instruction: "The
  saving settings issuesis becoming boring … Saving settins should not be so complicated"). `players/<slug>/name` (squeezelite
  `-N`) is the player's name. Two things write it, and nothing else may: the Settings window's Save,
  for a Name typed there (`PlayerIdentity.writeName`, before settings.json, for the names
  `Settings.renames(since:devices:)` gives against what the window opened on), and squeezelite, for a
  rename made in LMS. The agent only makes a missing one (`createNameFile`), and restarts a running
  engine at a settings change only when the renamed player's file already holds the new name and
  LMS (connected) does not have it already (`restartsForRename`, LMS's name from the 5 s `players`
  check, `PlayerState.name`). Both ways of renaming are supported (Simon, 2026-10-15: "players can
  be renamed via LMS Player settings or via the app"): the Settings window shows each player's name
  from its name file (`Settings.withCurrentNames`, in `PlayerModel.reload`), so an LMS rename shows
  there and a Save of anything else writes it into settings.json without a restart; the menu shows
  the name file's name too (`writeStatus`). An empty name file counts as none. Why: from 0.4.0 the AGENT applied settings.json's names to the file and had to
  guess which ones were typed: 0.4.5 compared old and new settings (lost a rename saved while off),
  the 2026-10-14 tree kept a `settings-name` record, the 2026-10-15 tree added a `saved` flag, and each
  guess missed a case (CODE-REVIEW 2026-10-14 #2, 2026-10-15 #1, 2026-10-15 (2) #1 and #2). Only the
  window knows what was typed. Never move name writing back into the agent, and never write a name
  from a default. Names are `PlayerSettings.fitName`d (one line, 63 bytes of whole characters, what
  squeezelite's `fgets` keeps); a blank one is refused at Save. Known and accepted: a rename in LMS
  in the ~2 s between Save and the engine's restart is overwritten by Save's name; a Save within ~5 s
  of an LMS rename, before the agent's next `players` check, restarts the engine once on the name
  it already has.

- **TWO LMS ON ONE HOST — DECLINED by Simon 2026-10-15** (/code-review 2026-10-15 (7) finding 1:
  "not supporting that use case at all its also highly unlikely on the same machine, not even sure
  its possible"). `ask_server_uuid(slimproto_ip, PORT)` asks for the UUID on UDP 3483 whatever
  slimproto port the Server setting names, and the name stamp (`struct name_server`,
  `is_connected_server`) holds no port. So two LMS on one host on different ports (a port mapping,
  e.g. a second Docker instance on 3484) would count as one server, and the second could store its
  default name over the player's. That setup is not supported. Not a finding, and passing
  `slimproto_port` is not to be offered as a fix. Re-raise only with a real user running two LMS on
  one host.

- **FOLLOW'S BUILT-IN FALLBACK — DECLINED by Simon 2026-10-15** (/code-review 2026-10-15 (7) finding
  2). When the macOS output is a DAC whose own player is on, *Follow the macOS output* takes
  `devices.first(where: \.isBuiltIn)` (Settings.swift), the first built-in output in `squeezelite -l`
  order. The review's case (headphones in the jack, speakers listed first, sound out loud) is not a
  finding: "headphones become primary output when they are plugged in", so plugging them in moves
  the macOS output off the DAC and the fallback does not run. Do not re-raise the choice between
  built-in outputs.

