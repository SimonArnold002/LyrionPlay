# Upstream

This directory is squeezelite by Adrian Smith and Ralph Irving, taken at the commit below, plus
the changes listed under "Our changes":

| | |
|---|---|
| repository | https://github.com/ralph-irving/squeezelite |
| commit | `ab20df3dff76122b9e4f426cffd0346e752b93da` (master, 2026-10-03) |
| version | 2.0.0-1609 (`squeezelite.h` `MICRO_VERSION`) |
| archive | `https://github.com/ralph-irving/squeezelite/archive/ab20df3dff76122b9e4f426cffd0346e752b93da.tar.gz` |
| archive SHA-256 (as downloaded 2026-10-09) | `d5ec9de950ecfd5ab7aa52fd9cac1f07c46e4c62fdfd208ab91ec42145c378e7` |
| licence | GPLv3 (`LICENSE.txt`); this directory stays GPLv3 |

## Our changes

Modified by CrystalGipsy for LyrionPlay, from 2026-10-09 (the dates of each change are in the git
history and the repo's `CLAUDE.md`). This list is the notice GPLv3 section 5(a) asks for. Every change
to an upstream file is listed here, so a later upstream update can be merged by hand.

New files (ours): `output_coreaudio.c`, `output_coreaudio_conv.h`, `Makefile.coreaudio`,
`tests/test_conversion.c`, `tests/test_output_coreaudio.c` (built with upstream's `output.c`,
`buffer.c`, `output_pack.c` and `dop.c`, which it links as they are).

Changes to upstream files, all inside `#if COREAUDIO` except the Makefile lines, the
`load_player_name` split in `slimproto.c`, and `send_packet`/`sendSETDName` returning whether they
wrote everything:

- `squeezelite.h`
  - On `__APPLE__`, `PORTAUDIO` is defined only `#if !defined(COREAUDIO)`.
  - `COREAUDIO` is normalised to 0/1 next to the `ALSA` switch.
  - `struct outputstate` gains `ca_reopen` and `volume_fixed`.
  - Prototypes for `output_coreaudio.c` (`ca_report_format` among them).
- `main.c`
  - Usage text for `-a <f>:<e>:<x>:<h>`, `-V` and `-X`; `-V`/`-X` take no argument here.
  - `" COREAUDIO"` added to the build options.
  - `ca_hw_volume` / `ca_linear_volume` variables and their `case 'V'` / `case 'X'`.
  - `output_init_coreaudio()` and `output_close_coreaudio()` calls.
  - `-n` and `-N` together are allowed: `-n` is the name a new player offers, `-N` the file that holds
    LMS's name once LMS has named the player.
- `slimproto.c`
  - In the main loop, `output.ca_reopen` is cleared, then `_ca_open()` is called; the
    PortAudio block clears after its call, which would lose a request raised meanwhile.
  - `process_audg` sets `output.volume_fixed = !audg->adjust` before `set_volume()`.
  - In the main loop, after `UNLOCK_O`, `ca_report_format()` (DoP or PCM, and the idle release, for
    the agent's menu).
  - `send_packet` and `sendSETDName` return whether every byte was written (upstream: `void`; the
    other callers still ignore it).
  - `name_from_lms`: set when the `-N` file held a name at start, LMS set one, or the player's name
    offer (its `-n` name, or its name to a server that has not named it) was written in full
    (`name_offered`: LMS's pref is that name then, answered or not). `process_setd` answers LMS's
    name query with an empty name while it is set, so LMS sends its own: LMS owns the name, and a
    queued LMS rename and the player's name can no longer chase each other. An empty `-N` file falls
    back to `-n`.
  - A name LMS sends, and the `-N` file read at start, are cut to 63 bytes at a whole UTF-8 character
    (`fit_name`; upstream keeps 64 bytes and reads back 63, either cut inside a character).
  - The servers that have named the player, kept beside the `-N` file as `<file>.server` (one line
    each, oldest first: its IPv4 address, then a space and its LMS `server_uuid` when it answered;
    at most 8; `add_name_server` at each name LMS sends and at each offer of the player's name
    written in full (an offer equal to LMS's name gets no answer), which keeps a line's UUID when this connect got
    none; written after the name file: `store_name_servers`, read at start whatever the name file
    holds: `load_name_servers`).
    Only those servers get the empty answer (`named_by_this_server`, `is_connected_server`: the UUIDs
    decide when both are known, else the address); any other (a changed server, a new LMS, LMS's
    `serv` switch) is offered the name, as upstream, so the player keeps it there. All of them, not
    only the last: LMS holds a rename for a disconnected player for 300 s, so a player that left a
    server and came back would otherwise offer its name across that rename. No stamp (a file from
    before it) keeps the empty answer.
  - The `-N` file (`store_name`) and its stamp are written as `<file>.tmp`, checked, flushed to the
    disk itself (`F_FULLFSYNC`, else `fsync`) and renamed over the file, where upstream writes the
    `-N` file in place: a write cut short (a full disk, a power cut) would leave it empty, which reads
    as a new player and offers `-n` over LMS's name. A file that already holds the text is not
    written (`file_holds`): LMS sends its name at every connect.
  - `ask_server_uuid`: in the main loop, after `connected` and before the HELO, LMS's discovery
    request (`eUUID`) sent by UDP to the server's own address, port 3483; two tries of 250 ms;
    `parse_server_uuid` reads the `E` TLV answer.
  - Upstream's `-n` / `-N` reading moved, unchanged but for the lines above, out of `slimproto()`
    into `load_player_name()`, so `tests/test_slimproto_name.c` can call it.
- `Makefile`
  - `OPT_COREAUDIO`.
  - `output_coreaudio.c` added to `SOURCES`.
  - `LINK_COREAUDIO = -framework CoreAudio -framework CoreFoundation` in the link branch.

## Updating

Download the new commit's archive, diff it against the commit above, and re-apply the changes
listed here. Record the new commit, version and SHA-256 in this file.

Then run `sh scripts/test.sh`: `tests/test_output_coreaudio.c` links the new `output.c`,
`buffer.c`, `output_pack.c` and `dop.c` unchanged (since 2026-10-11; before, it carried hand-made
copies of `_output_frames` and `output_flush`, and twice a rule missing from a copy hid a bug), so
its named tests and its scenario matrix run the new upstream rules against `output_coreaudio.c`.

Then re-read the upstream rules `output_coreaudio.c` relies on against the new `output.c`, because
the suite shows only the behaviour they cause, not a rule that moved:
- the delay around a track start (`_output_frames`, output.c:128-151: the rate delay on a rate
  change, the DSD delay on a format change, half before the switch, `delay_active`), copied in
  `_start_delay`;
- `output_flush`: it empties the buffer but leaves `track_start` (`_track_pending`), clears
  `delay_active` (`_mark_switch_done`), and resets `current_sample_rate` to the default while the
  output is not open (`error_opening`) but leaves `outfmt` (the rate `_ca_open` opens at; the reason
  `_silence_fmt` reads `ca.track_rate`/`ca.track_fmt`, not that pair);
- `track_start` cleared only at a track start inside `_output_frames` (the IOProc records
  `ca.track_rate`/`ca.track_fmt` there) and by `output_flush_streaming` (strm f, from slimproto);
- `outfmt` changing only at the track start (`_silence_fmt`, which takes the pending track's format
  first: inside a DSD delay at a gapless boundary, a `-D <ms>` the app never sets, its first half
  then plays in the new format, where output.c plays the old);
- which states output.c plays silence in through `write_cb` (pause frames, `OUTPUT_START_AT`,
  stopped or buffering, an underrun), whose format `_silence_fmt` decides;
- `OUTPUT_OFF` among them (`output.state <= OUTPUT_BUFFER`), with nothing else done while off: no
  track start, no fade, no frames played. The IOProc's last call before an idle release's close
  calls `_output_frames` for exactly that silence, as `output_pa.c`'s callback does (since the LIVE
  TEST of 0.2.9, 2026-10-11; it was left zero before).
