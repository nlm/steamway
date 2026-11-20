# Cloud gaming on a Scaleway L4 instance

Play your Steam library on an Android TV or a laptop. The games run on a Scaleway
**L4-1-24G** GPU instance and are streamed to you with **Sunshine** (server) and
**Moonlight** (client).

```
 Scaleway L4-1-24G (Ubuntu)                                 Your home
 ┌───────────────────────────────────────────┐             ┌──────────────────────┐
 │ Xorg (virtual 1080p display, NVIDIA)      │             │ Android TV           │
 │   ├─ Openbox (window manager)             │  internet   │   Moonlight app      │
 │   ├─ Steam (Big Picture)                  │ ──────────► │   + gamepad          │
 │   └─ Sunshine ── NVENC H.264/HEVC/AV1 ────┼─────────────┼► Laptop              │
 │ PipeWire (game audio)                     │             │   Moonlight app      │
 └───────────────────────────────────────────┘             └──────────────────────┘
```

`setup-l4-gaming.sh` sets up the server side in one run. Once it has run, the
instance boots straight into a streamable Steam session and nobody needs to log in.

> **Tested** on 2026-11-19: an `L4-1-24G` in `pl-waw-2` with the *Ubuntu Noble GPU OS 13
> (Nvidia)* image (driver 580.178.04, `-server` packages). On that instance:
> - OpenGL and Vulkan both rendered on the L4.
> - Sunshine found the H.264, HEVC and AV1 NVENC encoders and created its virtual keyboard and mice.
> - Steam set itself up and opened Big Picture without anyone clicking anything.
> - A screen capture plus HEVC NVENC encode at 1080p sustained 60 fps.
>
> Not tested yet: an actual Moonlight stream, pairing, audio during a stream, and a game.

---

## What you need

| | |
|---|---|
| **Server** | A Scaleway `L4-1-24G` instance with an **Ubuntu 24.04** image. Scaleway's GPU image with the NVIDIA driver already installed saves a reboot. |
| **Network** | Ideally 25 Mbps or more at home for 1080p60, with low ping to the Scaleway region (Paris, Amsterdam or Warsaw). Wired Ethernet on the TV if possible. |
| **TV** | An Android TV / Google TV device that decodes HEVC well (Nvidia Shield or Chromecast with Google TV), plus a Bluetooth or USB gamepad. |
| **Laptop** | Windows, macOS or Linux. |
| **Steam account** | You'll need Steam Guard at first login, either on your phone or by email. |

**Cost:** you pay for every hour the instance is powered on. Power it off after playing (see [Daily use](#daily-use)).

---

## Part 1: Server

### 1. Create the instance

1. In the Scaleway console, create an instance: **GPU → L4-1-24G**, image
   **Ubuntu Noble GPU OS 13 (Nvidia)**, with your SSH key. L4s can be scarce; if a zone
   has none, try another (`pl-waw-2`, `fr-par-2`, …). With the CLI:
   ```bash
   scw instance server create zone=pl-waw-2 type=L4-1-24G \
     image=ubuntu_noble_gpu_os_13_nvidia root-volume=sbs:200G ip=new name=steamway
   ```
2. Give it enough disk for games: a **Block Storage** volume of 200 GB or more. Games are large.
3. Note the instance's **public IP**.

### 2. Lock down the security group

The project's *Default security group* **accepts all inbound traffic**. Create a dedicated
security group for this instance with **inbound default policy = drop**, and allow
traffic **from your home IP only** (find yours at e.g. `curl ifconfig.me` from home):

| Protocol | Ports | Purpose |
|---|---|---|
| TCP | 22 | SSH |
| TCP | 47984, 47989, 48010 | Moonlight control / pairing |
| UDP | 47998–48000, 48002, 48010 | Video, audio, input |

**Never open TCP 47990.** That is Sunshine's admin web UI. You'll reach it through
an SSH tunnel instead.

> If your home IP changes (most residential connections do sometimes) and streaming
> stops connecting, update this rule.

### 3. Run the setup script

From your laptop:

```bash
scp setup-l4-gaming.sh root@<SERVER_IP>:
ssh root@<SERVER_IP>
ALLOW_FROM=<YOUR_HOME_IP>/32 bash setup-l4-gaming.sh
```

- If the image had **no NVIDIA driver**, the script installs one and stops with
  *"Reboot, then run this script again"*. Run `reboot`, SSH back in and run the
  same command again.
- A full run takes about 5–10 minutes. At the end it prints a summary with the next steps.

**Options** (set as environment variables before running the script):

| Variable | Default | Meaning |
|---|---|---|
| `GAMER_USER` | `gamer` | Linux account that runs Steam and Sunshine |
| `RESOLUTION` | `1920x1080` | Virtual display size, e.g. `2560x1440` |
| `REFRESH` | `60` | Refresh rate in Hz |
| `ALLOW_FROM` | any | Source IP/CIDR for the ufw rules (only used if ufw is active) |
| `SUNSHINE_VERSION` | `2026.1119.204022` | Exact Sunshine release to install. It is pinned on purpose (there is no `latest`); bump it after testing a new release. The script only downloads from GitHub when the installed version differs from the pin, and then installs exactly the pin, even if that means a downgrade. The default is a pre-release: the stable v2026.914 has a bug that makes Steam drop and reconnect virtual Switch Pro controllers every few seconds ([libvirtualhid #176](https://github.com/LizardByte/libvirtualhid/issues/176)). |

### 4. What the script sets up

- NVIDIA Xorg, OpenGL and Vulkan libraries (64- and 32-bit), plus the NVENC and FBC libraries, matched to the installed driver.
- `/etc/X11/xorg-headless.conf`: a virtual monitor on the GPU, since the L4 has no video outputs.
- `xorg-headless.service`: a system service that starts Xorg on `:0` at boot.
- The user `gamer` with lingering enabled, so its services start at boot without anyone logging in:
  - `desktop.service`: the Openbox window manager
  - `steam.service`: Steam in Big Picture mode
  - `sunshine-headless.service`: the Sunshine stream host
- Input from Moonlight:
  - The Xorg input driver (`xserver-xorg-input-libinput`), so Xorg uses Sunshine's virtual keyboard and mouse.
  - Access to `/dev/uinput` (keyboard, mouse, Xbox pads) and `/dev/uhid` (Switch Pro and PlayStation pads)
    for the `input` group, since a headless server has no logged-in seat.
  - `linux-modules-extra` for the running kernel, plus the `linux-image-generic` meta-package so kernel
    updates keep bringing it (Scaleway's image uses `linux-virtual`, which leaves it out). It provides
    `uhid`; without it, every controller is emulated as an Xbox pad. This also installs the pending
    kernel update and ~500 MB of firmware packages, unused on a VM but harmless.
- An Openbox rule (`~gamer/.config/openbox/rc.xml`) that opens Steam games full-screen without a title
  bar. Otherwise a windowed game gets a frame, and the bottom of its image is pushed off the stream.
- Sunshine set to X11 capture with the NVENC encoder. Its web UI only accepts connections from localhost or the LAN.
- A small `zenity` stand-in in `/usr/local/lib/steamway/`, used only by the Steam service.
  Ubuntu's `steam-installer` asks "Install Steam?" in a dialog on its first run; the
  stand-in answers yes to that one question so Steam installs unattended, and passes
  every other dialog to the real zenity. The first start downloads about 3 GB and takes
  about 3 minutes before the login screen appears.
- A random web UI password, saved in `/root/sunshine-webui-credentials.txt`.

### 5. Pair a client

Each client device (TV, laptop) is paired **once**, using a PIN.

**Quick way:** on the client, start Moonlight and add the server (see Part 2). Moonlight
shows a **4-digit PIN**. While the PIN is on screen, run this from your laptop:
```bash
ssh root@<SERVER_IP> sunshine-pair 1234 living-room-tv
```
The device name is optional (default: the name Moonlight sends). The `sunshine-pair` command (installed by the script) sends the PIN to
Sunshine's API on the server, so you don't need a tunnel or a browser.

**Through the web UI** (if you'd rather use the browser):

1. Open an SSH tunnel from your laptop, and leave it open:
   ```bash
   ssh -L 47990:localhost:47990 root@<SERVER_IP>
   ```
2. Show the web UI password (on the server):
   ```bash
   cat /root/sunshine-webui-credentials.txt
   ```
3. Browse to **https://localhost:47990**, accept the self-signed certificate warning and log in.
4. On the client, start Moonlight and add the server (see Part 2). Moonlight shows a **4-digit PIN**.
5. In the web UI, open the **PIN** tab, enter the PIN and a name for the device, and click **Send**.

### 6. First Steam login

1. In Moonlight, open the **Desktop** app. You'll see the Steam window on a plain desktop.
2. Log in to Steam and approve the Steam Guard prompt. Tick *Remember me*.
3. Let Steam finish its first update.
4. **Enable Proton** for Windows games: *Settings → Compatibility → Enable Steam Play for all other titles*.
5. Install a game, ideally on the large volume. To add it as a Steam library folder: *Settings → Storage → Add Drive*.

From now on, launch **Steam Big Picture** from Moonlight.

---

## Part 2: Clients

### Android TV / Google TV

1. **Install** *Moonlight Game Streaming* from the Play Store on the TV.
2. **Pair a gamepad** with the TV: *Settings → Remotes & Accessories → Add accessory*.
   Use an **Xbox or PlayStation** controller. Android TV handles those correctly.
   > **Nintendo Switch Pro controllers can map wrongly on Android TV.** On some
   > boxes (tested: Freebox Player Pop, over USB and Bluetooth), the buttons
   > arrive mixed up and the D-pad doesn't arrive at all. The cause is the box's
   > Android firmware, not the server or the controller: it's a known, open Moonlight
   > Android issue ([#842](https://github.com/moonlight-stream/moonlight-android/issues/842)).
   > The same controller works on a Mac. Also, Android TV keeps the controller's
   > **Home** button for itself, so pressing it leaves Moonlight.
3. Open Moonlight. The server is on the internet, not your LAN, so it won't appear
   automatically. Choose **Add PC manually** (the **+** icon) and enter `<SERVER_IP>`.
4. Select the PC. Moonlight shows a PIN. While it is on screen, pair from your laptop with
   `ssh root@<SERVER_IP> sunshine-pair <PIN> tv` (or use the web UI, Part 1, step 5).
5. Open Moonlight's **Settings** before the first session:

   | Setting | Recommended |
   |---|---|
   | Resolution / FPS | 1080p / 60 FPS (match the server's `RESOLUTION`/`REFRESH`) |
   | Video bitrate | 20–30 Mbps (lower it if you see stutter) |
   | Video codec | HEVC (try AV1 if the device supports it) |
   | Frame pacing | *Balanced* |
   | Optimize game settings | Off |

6. Choose **Steam Big Picture** and play. To leave a game, press **Back + Start + LB + RB**
   on the gamepad (Start + Select + L1 + R1), then choose *Quit session* on the PC tile.
   Simply disconnecting leaves the session running on the server.

### Laptop (Windows / macOS / Linux)

1. **Install** Moonlight from <https://moonlight-stream.org>. On Linux, Flatpak is easiest:
   ```bash
   flatpak install flathub com.moonlight_stream.Moonlight
   ```
2. **Add the server:** click **+** → `<SERVER_IP>` → pair with the PIN, as above.
3. Use the **Settings** from the TV table above. Optionally:
   - **Windowed mode** if you want other windows visible next to the stream.
   - **Capture system keyboard shortcuts** (fullscreen only) so Alt+Tab etc. go to the game.
   - **Nintendo Switch Pro controller:** connect it to the Mac (Bluetooth or USB) *before*
     starting the stream. If A/B and X/Y are swapped, turn on **"Swap A/B and X/Y gamepad
     buttons"**. Change only that setting, not Steam's "Use Nintendo button layout" as well,
     or the two cancel out.
4. Useful shortcuts:

   | Shortcut | Action |
   |---|---|
   | `Ctrl+Alt+Shift+Q` | Disconnect |
   | `Ctrl+Alt+Shift+X` | Toggle fullscreen |
   | `Ctrl+Alt+Shift+Z` | Release/capture the mouse |
   | `Ctrl+Alt+Shift+S` | Show performance stats (latency, dropped frames) |

---

## Daily use

**Start playing**
1. Scaleway console (or CLI): **Power on** the instance. It takes about 1–2 minutes to boot.
2. Open Moonlight → your server → **Steam Big Picture**.

**Stop playing**
1. Quit the game, then quit the session in Moonlight.
2. **Power off** the instance in the console to stop GPU billing:
   ```bash
   # Or with the Scaleway CLI
   scw instance server stop <SERVER_ID> zone=<ZONE>
   ```
   Your games, Steam login and pairings stay on the volume.

> Stopping releases the GPU. At busy times Scaleway may have no L4 free when you
> want to start again. You'd have to wait or try another zone.

> **Check how the IP is set up.** If the public IP is *dynamic*, it can change after
> a stop/start, and you'd have to re-add the PC in Moonlight. Reserve a **flexible IP**
> and attach it to the instance so the address stays the same.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Moonlight can't find or connect to the server | Security group rules (Part 1, step 2), your current home IP, and whether Sunshine is running: `journalctl _SYSTEMD_USER_UNIT=sunshine-headless.service -e` |
| Black screen in the stream, only the mouse cursor visible | If Steam is running but its window is black, check that `steam.service` starts Steam with `-cef-disable-gpu-compositing` (the script sets this). Without it, Steam's interface stays black on a headless NVIDIA setup and `logs/webhelper.txt` fills with `GLXBadPixmap` errors. Then restart Steam: `sudo -u gamer XDG_RUNTIME_DIR=/run/user/$(id -u gamer) systemctl --user restart steam` |
| Black screen, no cursor or no Steam window | Is Xorg running? `systemctl status xorg-headless`, and `grep -E "EE|WW" /var/log/Xorg.0.log` |
| Xorg fails with "no screens found" | Check that `nvidia-smi` works and that the BusID in `/etc/X11/xorg-headless.conf` matches `nvidia-smi --query-gpu=pci.bus_id --format=csv` |
| No sound | Is PipeWire running for the gamer user? `sudo -u gamer XDG_RUNTIME_DIR=/run/user/$(id -u gamer) pactl info` |
| Mouse doesn't move and keyboard does nothing | `grep "No input driver" /var/log/Xorg.0.log`. If Sunshine's `libvirtualhid` devices are listed as ignored, install `xserver-xorg-input-libinput` (the script does this) and run `systemctl restart xorg-headless` |
| Gamepad or keyboard doesn't respond | `ls -l /dev/uinput /dev/uhid` should show group `input` and mode `crw-rw----`. Is gamer in `input`? `id gamer` |
| A Switch Pro or PlayStation controller shows up as an Xbox pad, with buttons mixed up | `journalctl _SYSTEMD_USER_UNIT=sunshine-headless.service \| grep uhid`. If it says *failed to open /dev/uhid*, the `uhid` module is missing for the running kernel: `apt install linux-modules-extra-$(uname -r)` or re-run the script |
| Steam shows "controller connected / disconnected" every few seconds | Sunshine older than the version pinned by `SUNSHINE_VERSION` (`dpkg -l sunshine`). Steam's `logs/controller.txt` shows `hid_read failure`. Re-run the script to upgrade |
| A game has a title bar, or its bottom edge is cut off | The game is windowed and Openbox frames it. Check that `~gamer/.config/openbox/rc.xml` has the `steam_app_*` rule (the script adds it), then restart the game, or set it to full-screen in its own options |
| Stutter or blocky video | Lower the bitrate in Moonlight, use wired Ethernet, and check the stats overlay. High *network* latency means the region is too far; high *decode* latency means the TV box is too slow (try H.264) |
| Steam closed and won't come back | `sudo -u gamer XDG_RUNTIME_DIR=/run/user/$(id -u gamer) systemctl --user restart steam` |
| A game won't start | Check its ProtonDB rating. Games with kernel anti-cheat often block virtual machines |

**Restart the whole stack:**
```bash
systemctl restart xorg-headless
systemctl restart user@$(id -u gamer)
```

**Change the resolution later:** run the script again with a new value, e.g.
`RESOLUTION=2560x1440 bash setup-l4-gaming.sh`. It regenerates the Xorg config and
restarts the services, and keeps the existing Sunshine settings and password.

---

## Security notes

- The Sunshine web UI (47990) is reachable only through the SSH tunnel. Keep it that way.
- Restrict every inbound port to your home IP in the security group.
- Pairing is per device. Remove old clients in the web UI under **Troubleshooting → Unpair**.
- Xorg is started without an auth file, so any local user on the server can connect
  to display `:0`. That's fine on a single-user gaming box, but don't run other
  people's workloads on it.
