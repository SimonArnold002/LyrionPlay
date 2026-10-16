# Changelog

## 0.4.14 — 2026-10-16

The first release of LyrionPlay: a bit-perfect Lyrion Music Server player for Apple Silicon Macs,
built on squeezelite, with a menu bar app.

### Features

- **Bit-perfect on a DAC.** Exclusive (hog) mode, with the DAC switched to each track's sample
  rate. Samples reach the DAC unchanged at full volume.
- **One player, or one per device.** *Follow the macOS output* is one LMS player that plays
  wherever your Mac's sound goes. Any DAC or other output can also be switched on as a player of
  its own, with its own name, volume and settings, or both.
- **Your DAC's rates.** LMS learns the DAC's highest sample rate and transcodes anything above it;
  rates the DAC lacks below that are resampled in the player, only when needed.
- **DSD.** Sent as DoP to DACs you switch DoP on for, in exclusive or shared mode, and converted to
  PCM for the rest. The menu shows the DSD rate while DoP plays.
- **Volume, per player.** *Device's own volume*: the LMS slider moves the Mac's or the DAC's own
  volume, and a change on the Mac moves the LMS slider; the level stays where you put it through
  track and album changes, pause and resume. *Software* where the Mac can't set the device's
  volume. *Fixed* on a DAC: LyrionPlay sets LMS's fixed output level, and a DAC whose volume the
  Mac sets holds the level LMS had.
- **LMS replay gain**, applied by the player exactly as LMS sends it.
- **LMS owns the player name.** Rename a player in LMS and LyrionPlay follows; a player LMS has
  never seen offers its default name ("<Mac's name> <device's name>").
- **Remove a player** from its options: it leaves LyrionPlay and LMS, so a device can be added
  fresh.
- **Menu bar app.** Switch LyrionPlay on and off, see each player's server, device and sample
  rate, and set each player's options. In Material each player shows with an Apple icon.
- **Signed by you.** `install.sh` signs your copy with a certificate made on your own Mac, so no
  Apple developer account is involved, and updates keep your Local Network approval.
- **Licences.** The codec libraries' source for each release is attached to its release page as
  `LyrionPlay-<version>-codec-sources.zip`; every licence text ships in the app.
