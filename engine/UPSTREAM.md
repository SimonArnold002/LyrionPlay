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

Changes to upstream files, all inside `#if COREAUDIO` except the Makefile lines:

- `squeezelite.h`
  - On `__APPLE__`, `PORTAUDIO` is defined only `#if !defined(COREAUDIO)`.
  - `COREAUDIO` is normalised to 0/1 next to the `ALSA` switch.
  - `struct outputstate` gains `ca_reopen` and `volume_fixed`.
  - Prototypes for `output_coreaudio.c` (`ca_report_format` among them).
- `main.c`
  - Usage text for `-a <f>:<e>`, `-V` and `-X`; `-V`/`-X` take no argument here.
  - `" COREAUDIO"` added to the build options.
  - `ca_hw_volume` / `ca_linear_volume` variables and their `case 'V'` / `case 'X'`.
  - `output_init_coreaudio()` and `output_close_coreaudio()` calls.
- `slimproto.c`
  - In the main loop, `output.ca_reopen` is cleared, then `_ca_open()` is called; the
    PortAudio block clears after its call, which would lose a request raised meanwhile.
  - `process_audg` sets `output.volume_fixed = !audg->adjust` before `set_volume()`.
  - In the main loop, after `UNLOCK_O`, `ca_report_format()` (DoP or PCM, and the idle release, for
    the agent's menu).
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
