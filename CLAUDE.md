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
engine/               squeezelite at a pinned commit (UPSTREAM.md) + output_coreaudio.c, and the
                      player-name rules in slimproto.c (LMS OWNS THE PLAYER NAME)
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
                      upstream's output.c, with the SCENARIO MATRIX), engine name
                      (engine/tests/test_slimproto_name.c, slimproto.c's name rules against a
                      model of LMS), swift test,
                      install.sh in a sandbox (scripts/tests/test_install.sh). No device, app,
                      keychain or server is touched
scripts/install.sh    what every user runs: own certificate, unquarantine, sign, install
scripts/uninstall.sh  removes the app, agent, settings, logs (--remove-certificate too)
INSTALL.md            the user-facing install guide, shipped in the release zip with INSTALL.html
docs/ledger/          the Review Ledger: index.md (grep it first), decisions.md (§A2),
                      disproven.md (§A3), open.md (§B), closed.md (§C)
docs/live-test.md     the live test with the output tap (what reached the DAC)
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
**Before any live test with the output tap** (`LYRIONPLAY_TAP`, an engine run by hand, the agent
booted out): read `docs/live-test.md` first and follow it step by step.

## Review Ledger — READ THIS BEFORE REPORTING ANY FINDING

The workspace `CLAUDE.md` one level up holds the three fleet-wide gates. This ledger holds what
is settled for THIS project. Review and fix happen in separate sessions, so a decision, a
disproven belief or a cleared finding that is not written here will be re-reported as a finding.

**Before you report a finding, propose a change, or answer "is this a bug / should we change
X":** grep `docs/ledger/index.md` for every symbol, file and subject you touch
(`grep -n -i '<symbol>' docs/ledger/index.md`). For each hit, grep its closing phrase across
`docs/ledger/` (`grep -rn '<PHRASE>' docs/ledger/`) and read that entry before you write. A hit
marked DECIDED, DECLINED, BY DESIGN, NOT A FINDING, ACCEPTED or WRONG is settled: say so and cite
it instead of re-raising it.

The ledger lives in `docs/ledger/`; its sections keep their old names:
- the DECLINED / SETTLED INDEX → `docs/ledger/index.md`
- §A2 NOT FINDINGS — LyrionPlay decisions → `docs/ledger/decisions.md`
- §A3 DISPROVEN beliefs → `docs/ledger/disproven.md`
- §B KNOWN-OPEN AND ACCEPTED → `docs/ledger/open.md`
- §C CLOSED FINDINGS → `docs/ledger/closed.md`

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


### D. ADDING TO THIS LEDGER
When a finding is declined, accepted, parked or disproven, add it in the same session: the entry
in its section and its index row, with the reason as a fact that can be disproven.
