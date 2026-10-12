# Installing LyrionPlay

LyrionPlay plays music from your Lyrion Music Server (LMS) on your Mac. LMS sees it as an ordinary
squeezelite player.

It lives in your menu bar and offers:

- **Bit-perfect playback on a DAC.** It switches the DAC to each track's sample rate and takes
  exclusive use of it while playing.
- **DSD**, sent as DoP to DACs that accept it, and converted to PCM for those that don't.
- **LMS replay gain.**
- **Volume both ways:** with *Device's own volume*, the LMS slider and your Mac's volume keys move
  each other (the keys only when the output is the Mac's built-in speakers or Follow the macOS
  output).

## What you need

- A Mac with Apple Silicon (M1 or later) running macOS 14 Sonoma or later.
- Lyrion Music Server on your network.
- An administrator account, to install into Applications. Without one, LyrionPlay installs into
  the Applications folder in your home folder instead.

## Why you sign it yourself

macOS opens an app without complaint only if it is signed by a developer who pays Apple for a
certificate. LyrionPlay isn't, so you sign your own copy instead. That takes one command.

The installer does it for you:

1. It creates a code-signing certificate called **LyrionPlay Signing** in your login keychain. It
   does this the first time only.
2. It signs LyrionPlay with that certificate.

Some things to know about the certificate:

- **Its private key never leaves your Mac**, and nobody else's signature is involved.
- **It is used only to sign LyrionPlay**, and it lasts ten years.
- **It keeps your permissions across updates.** Each new version is signed with the same
  certificate, so macOS treats it as the same app and keeps the permissions you gave it,
  such as Local Network.
- **macOS lists it as "not trusted".** That is normal: nothing vouches for it except you.

## Install

1. **Download** `LyrionPlay-<version>.zip` and double-click it. Finder unzips it into a folder in
   your Downloads, containing `LyrionPlay.app`, `install.sh`, `uninstall.sh` and this guide.
2. **Open Terminal.** It's in Applications → Utilities, or press ⌘Space and type *Terminal*.
3. **Type `sh` and a space.** Then drag `install.sh` from the folder into the Terminal window, and
   press Return. It should look like this:

   ```
   sh ~/Downloads/LyrionPlay-<version>/install.sh
   ```

   with your version's number in place of `<version>`.

   Running it through `sh` means macOS has no reason to block the script itself.
4. **Watch it work through its steps.** It takes a few seconds:
   1. checks your Mac;
   2. creates your certificate, the first time only;
   3. copies the app to Applications;
   4. removes the "downloaded from the internet" flag, which is what would otherwise make
      macOS block the app;
   5. signs the app with your certificate;
   6. installs it;
   7. opens it.

   If macOS asks for your login password, or asks whether `codesign` may use the key "LyrionPlay
   Signing", enter your password and click **Always Allow**.
5. **Look for the icon:** LyrionPlay's play arrow and waveform appears in the menu bar.

## First run

1. **Switch the player on:** click the menu bar icon and turn on the switch.
2. **Click Allow twice.** macOS asks whether LyrionPlay may find devices on your local network:
   once for the player and once for its audio engine. The player can't reach your server
   without both.
3. **Play something.** The player appears in LMS (in Material or any other LMS interface) under
   your Mac's name. Material shows it with an Apple icon.
4. **Choose your options:** click the icon, then **Settings…**. See the next section.

The menu shows whether the player is connected to your server, the output device with the rate it
plays at (for DSD sent as DoP, the DSD rate, such as DSD64), a lock when it has the device to itself,
and the track playing.

Quitting from the menu stops the player as well. Both start again when you log in, or when you open
LyrionPlay from Applications. If the menu ever disappears while the player is running, it comes back
by itself within a few seconds.

## Settings

**Name** is the player's name in LMS; it starts as your Mac's name. **Server** is left empty to find
your server on the network by itself; enter its name or IP address if it is on another network.

**Output device.** Either follow the macOS sound output, or pick one device. Picking the device is
the better choice for a DAC.

**Exclusive mode** is on by default for external DACs (USB, Thunderbolt and the like), and off for
the Mac's own outputs. While playing, LyrionPlay:
- takes the DAC for itself, so other apps can't play through it;
- sets the DAC to each track's sample rate;
- sends the samples unchanged.

It lets go of the DAC 30 seconds after you stop. You can change that time under Advanced. At 0 it
reads *never*: LyrionPlay then keeps the DAC for as long as the player is on, even while stopped.

**DAC accepts DSD over PCM (DoP).** Turn this on only if your DAC supports DoP; macOS cannot detect
it.
- With it off, DSD is converted to PCM, so it still plays.
- DoP needs a PCM rate of a sixteenth of the DSD rate: DSD64 needs 176.4 kHz and DSD128 needs
  352.8 kHz. DSD faster than your DAC's top PCM rate allows is converted to PCM.

**LMS volume.**
Each device offers only the choices it can take: *Device's own volume* only when the Mac can set
its volume, and *Fixed at 100%* only on a DAC, not on the Mac's own outputs (built-in speakers and
headphones, Bluetooth, AirPlay, HDMI).

- *Device's own volume*: the LMS volume slider and your Mac's volume follow each other. Move the
  LMS slider and your Mac's volume (built-in speakers, headphones) or the DAC's hardware volume
  moves with it. Use your Mac's volume keys, or mute, and the LMS slider follows a moment later. The
  volume keys only work when LyrionPlay's output is the Mac's built-in speakers or **Follow the
  macOS output**.
- *Software*: LyrionPlay scales the samples instead.
- *Fixed at 100%*: LMS sends the music at full level, and you set the volume on the DAC or your
  amplifier. LyrionPlay sets the
  player's **Output level is fixed at 100%** in LMS for you, and turns LMS's volume control back on
  when you play to a device set to one of the other two. Each device keeps its own choice. Coming
  from *Software*, this is louder: turn the DAC down before you save.

  LMS's own Volume Control setting for this player follows the choice here: change it in LMS or
  Material, and LyrionPlay puts it back within a few seconds.

**Silence on a rate change.** Some DACs mute for a moment after switching rate. If the start of a
track gets clipped, add a little silence here.

**Advanced:** the release time above; **Resampling quality**, used only when your device lacks a
track's rate; **Log detail**: Debug writes more to the logs.

**Save** keeps your changes, **Save and Close** keeps them and closes the window, and **Revert** goes
back to what is saved. If a save fails, the window says why and keeps your changes on screen.

### For bit-perfect playback

- **Use your DAC's or amplifier's own volume control.** In LyrionPlay's Settings, set the DAC's
  **LMS volume** to **Fixed at 100%**.
- **Replay gain** is set in LMS, under the player's settings → Audio. LyrionPlay applies it, but it
  changes the level, so tracks played with replay gain are not bit-perfect.

## Updating

Download the new zip and run its `install.sh` the same way. It:
- finds your existing certificate;
- signs the new version with it;
- swaps it in, restarting the player only if the player itself changed.

macOS won't ask for any permission again.

## Uninstalling

```
sh ~/Downloads/LyrionPlay-<version>/uninstall.sh
```

This stops the player and removes the app, its background service, its settings and its logs. It
keeps your certificate, in case you reinstall. To delete the certificate too, add
`--remove-certificate`.

Two things it can't remove:
- **LMS keeps listing the player** until it forgets it.
- **System Settings → Privacy & Security → Local Network may still list** `lyrionplay-agent` and
  `squeezelite`. The entries do nothing once the app is gone.

## Installing by hand, without the script

1. **Create the certificate.** Open Keychain Access: press ⌘Space and type *Keychain Access*. Then,
   from its menu, choose Keychain Access → Certificate Assistant → **Create a Certificate…** and
   set:
   - Name: **LyrionPlay Signing**
   - Identity Type: **Self-Signed Root**
   - Certificate Type: **Code Signing**

   Then click Create.
2. **Install the app:** drag `LyrionPlay.app` into Applications.
3. **Remove the download flag and sign the app.** In Terminal, run these four commands. Signing
   goes from the inside out: the two helpers first, then the app itself.

   ```
   xattr -dr com.apple.quarantine /Applications/LyrionPlay.app
   codesign --force --options runtime -s "LyrionPlay Signing" -i com.crystalgipsy.lyrionplay.squeezelite /Applications/LyrionPlay.app/Contents/MacOS/squeezelite
   codesign --force --options runtime -s "LyrionPlay Signing" -i com.crystalgipsy.lyrionplay.lyrionplay-agent /Applications/LyrionPlay.app/Contents/MacOS/lyrionplay-agent
   codesign --force --options runtime -s "LyrionPlay Signing" /Applications/LyrionPlay.app
   ```

4. **Open LyrionPlay** from Applications.

For an update, quit LyrionPlay from its menu, then repeat steps 2 to 4.

### Without signing at all

You can skip signing:
1. Drag the app into Applications and open it.
2. When macOS refuses to open it, go to System Settings → Privacy & Security and click
   **Open Anyway**.

It works, but every update looks like a new app to macOS. You would approve it again, and click
Allow on the Local Network prompts again, after each update.

## If something goes wrong

- **The player doesn't appear in LMS.**
  - Check System Settings → Privacy & Security → Local Network: `lyrionplay-agent` and
    `squeezelite` must both be switched on.
  - If your server is on a different network, enter its address in Settings → Server.
- **Nothing plays on a DAC another app is using** (Audirvana, Roon or similar, in exclusive mode).
  `engine.log` says "device is held exclusively by another process". LyrionPlay keeps trying, and
  plays within about 5 seconds of the other app letting go.
- **The menu's status lags behind LMS.** LyrionPlay asks the server about the player every 5
  seconds, and `agent.log` says when the server is slow: "LMS check of … took N s" means it took
  over 2 seconds to answer, and "back under 2 s" follows when it recovers. "did not answer" or
  "no server found" means the server could not be reached: check that it is running, and the
  address in Settings → Server.
- **The menu bar icon has gone.** Open LyrionPlay from Applications.
- **Logs:** click the icon, then **Logs**. They are in `~/Library/Logs/LyrionPlay`:
  - `agent.log` is the background player;
  - `engine.log` is the audio engine;
  - `menu.log` is the menu app.

## Building from source

You need Apple's Command Line Tools: run `xcode-select --install` in Terminal. Then:

- `scripts/build.sh --install` builds LyrionPlay and installs it with your own certificate, exactly
  as above. The first build downloads and compiles CMake and the audio codec libraries, which
  takes a while.
- `scripts/build.sh --release` makes the two release zips: the app, and the codec libraries' source.
- Every build first runs the regression suite, `scripts/test.sh`, and stops if a test fails.

## Licences

- **Audio engine:** squeezelite by Adrian Smith and Ralph Irving, modified for LyrionPlay, under
  GPLv3. Its source code, and LyrionPlay's, is at
  [github.com/SimonArnold002/LyrionPlay](https://github.com/SimonArnold002/LyrionPlay): each
  version's under its tag (`v<version>`), and the source of the codec libraries built into the
  engine in `LyrionPlay-<version>-codec-sources.zip`, on the same release page as this download.
- **Menu bar app and background service:** MIT licence.
- **Third-party notices:** in `LyrionPlay.app/Contents/Resources/NOTICES.txt`, and each licence's full text in the `licences` folder beside it.

LyrionPlay is not affiliated with the Lyrion Music Server project.
