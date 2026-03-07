# IR blaster on Raspberry Pi / Linux

Use a USB IR transceiver to **learn** and **blast** infrared codes. The agent can replay learned buttons via the **ir-blast** skill.

## Supported hardware (mceusb driver)

| Dongle | USB ID | Notes |
|--------|--------|--------|
| **Microsoft eHome** | 045e:006d | Often “eHome Remote Control Keyboard”. Plug emitter into TX jack; some report `0x0 cabled` but still transmit. |
| **SMK (e.g. RXX6000-0141E)** | 0609:031d, 0609:0334 | SMK “MCE TRANCEIVR”; same mceusb driver. Check `dmesg | grep mceusb` for “SMK CORPORATION”. May report `0x0 cabled` but still transmit when emitter is plugged into TX port. |

After plugging in, run `ls -la /dev/lirc*` and `dmesg | grep mceusb` to see the device node and whether transmit ports are cabled. If you have more than one dongle, use the device that has the emitter plugged in (e.g. `./scripts/ir-blast.sh file.ir /dev/lirc1`).

## Hardware (Microsoft 045e:006d)

- **USB ID:** 045e:006d  
- **Product:** Microsoft IR Transceiver (Bulk IN + Bulk OUT → receive + blaster)  
- **Kernel driver:** `mceusb` (Media Center eHome USB) — **MCE_GEN1**.

**Check if your dongle can transmit:** After plugging in, run `dmesg | grep mceusb`. You want to see e.g. `(0x1 cabled)` or `(0x3 cabled)`. **If you see `(0x0 cabled)`:** Some dongles always report 0x0 even with the emitter plugged in (they don’t report cable-detect). So: (1) Plug the IR emitter into the TX jack(s) on the dongle. (2) Unplug USB, then plug the emitter in first, then plug USB back in. (3) Run `dmesg | grep "tx ports"` again. (4) **Try blasting anyway** — the hardware may still output; run a blast and watch the emitter with a **phone camera** (IR often shows as a purple/white flicker). If the emitter flashes, transmit works despite 0x0. Use the correct jack (often labeled “IR out” or “emitter”; 3.5mm). Without any emitter plugged in, no IR is emitted.

If the dongle is currently used as a **keyboard** (HID), the kernel has bound it to `usbhid`. To get raw IR, bind it to `mceusb` instead.

## 1. Check current binding

```bash
lsusb -t
```

Find the line for `045e:006d`. If the driver is `usbhid`, you need to unbind and use `mceusb`.

```bash
# List LIRC devices (only present if mceusb is bound)
ls -la /dev/lirc*
```

If you see no `/dev/lirc*`, the transceiver is not yet used as an IR device.

## 2. Unbind from HID and bind to mceusb

**Find the USB interface** (replace with your Bus/Device if different):

```bash
# Example: device on Bus 003, Device 002
ls /sys/bus/usb/devices/
# Find the directory that has idVendor 045e and idProduct 006d, e.g. 3-2
grep -l 045e /sys/bus/usb/devices/*/idVendor 2>/dev/null
cat /sys/bus/usb/devices/3-2/idVendor /sys/bus/usb/devices/3-2/idProduct
# Interface is usually 3-2:1.0
ls /sys/bus/usb/devices/3-2:1.0/
```

**Unbind from usbhid** (use the interface that shows driver `usbhid`, e.g. `3-2:1.0`):

```bash
sudo sh -c 'echo -n "3-2:1.0" > /sys/bus/usb/drivers/usbhid/unbind'
```

**Load mceusb and bind** (kernel may auto-bind when we unbind; if not, bind explicitly):

```bash
sudo modprobe mceusb
# If it didn’t auto-bind, find the interface and bind:
# sudo sh -c 'echo -n "3-2:1.0" > /sys/bus/usb/drivers/mceusb/bind'
```

**Verify:**

```bash
ls -la /dev/lirc0
# Optional: see kernel name
cat /sys/class/rc/rc0/name
```

## 3. Receive IR (raw waveform)

Use the script in this repo to read **raw pulse/space** timings (µs) from the dongle:

```bash
# List LIRC devices
./scripts/ir-receive.py --list

# Capture raw IR (each line = one pulse or space + duration in µs)
./scripts/ir-receive.py

# One-line summary per keypress (p= pulse, s= space, numbers = µs)
./scripts/ir-receive.py --summary
```

Point any IR remote at the dongle and press a button; you should see a stream of `PULSE` / `SPACE` lines (or one line per key with `--summary`). That is the “IR waveform” data you can later use to replay or decode protocols (NEC, RC-5, etc.).

## 4. Record a keypress and blast it back

**Record** (point remote at dongle, press one button, then press another so the first one is written; or press once and wait for the timeout):

```bash
./scripts/ir-receive.py --summary --record saved.ir
# Press a button on the remote; "Recorded to saved.ir" appears after the gap.
```

**Blast** the same waveform (needs `v4l-utils`):

```bash
sudo apt install -y v4l-utils   # if needed
./scripts/ir-blast.sh saved.ir
# Or: ir-ctl -d /dev/lirc0 --send=saved.ir
```

Saved files are in ir-ctl format (one pulse/space duration in µs per line, alternating).

## 5. Learn buttons for the agent (ir-learn → ir-blast skill)

To control a device (e.g. fan) by name from OpenClaw:

**1. Learn buttons on the Pi (one-time)**  
Run the interactive learner; it saves each button under a remote name and button name into the agent workspace:

```bash
cd /path/to/ironclaw
./scripts/ir-learn.py
# Remote name (e.g. fan_remote): fan_remote
# Press a button.  → point remote, press power
# Name for this button (e.g. power): power
# Press a button.  → press speed 1
# Name for this button: speed_1
# … then Enter to finish
```

Learned files go to `agents/pibot/workspace/ir-codes/<remote>/<button>.ir` and the catalog `ir-codes/REMOTES.md` is updated.

**2. Emit from the agent**  
When the user says "turn on the fan" or "blast fan power", the agent uses the **ir-blast** skill: it runs `emit.py fan_remote power` (or whatever remote/button names you used). The skill reads `REMOTES.md` and blasts the matching `.ir` file via `ir-ctl`.

**3. If the agent runs in Docker on the Pi**  
There is **no separate bridge service** for IR — the container gets the LIRC device via **device passthrough** only. You must add a Compose override so the container sees `/dev/lirc0`.

**3a. Create the override (once per agent directory)**  
Copy the example and fix the device path if your dongle is not `lirc0`:

```bash
cp agents/pibot/docker-compose.override.yml.example agents/pibot/docker-compose.override.yml
# If your dongle is /dev/lirc1, edit the file and use lirc1.
```

Contents of `agents/pibot/docker-compose.override.yml`:

```yaml
services:
  openclaw:
    devices:
      - /dev/lirc0:/dev/lirc0
```

**3b. Restart so the override is applied**  
`compose-up.sh` automatically includes `docker-compose.override.yml` when present:

```bash
./scripts/compose-up.sh pibot -d
```

**3c. Check that the container sees the device**  
On the host:

```bash
ls -la /dev/lirc0
docker exec pibot_secure ls -la /dev/lirc0
```

If the container shows "Permission denied" or no such device, either the override was not merged (confirm the override file exists and you restarted) or the container user (UID 1000) cannot access the device. On the host, make the device readable by the container user:

```bash
sudo chmod 666 /dev/lirc0
```

For **reliable IR after reboot**, see **5a. Reliable after reboot** below.

**Quick diagnose from repo root:**  
`./scripts/ir-check.sh pibot` — checks host device, override file, container visibility, and suggests fixes.

If your dongle is on `/dev/lirc1`, use that path in the override and set `IR_LIRC_DEVICE=/dev/lirc1` in `agents/pibot/.env` so the ir-blast skill uses it.

### 5a. Reliable after reboot

After a reboot, the bot often says it can't blast IR because (1) the LIRC device doesn't exist yet when the container starts, or (2) `/dev/lirc0` is created with root-only permissions so the container gets "Permission denied". Do the following so IR works every time.

**1. Udev rule (permissions)**  
Install the repo udev rule so `/dev/lirc*` is readable/writable by the container (mode 0666) after every boot:

```bash
cd /path/to/ironclaw
sudo cp scripts/99-lirc-permissions.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules && sudo udevadm trigger
```

Unplug and replug the IR dongle (or reboot), then check: `ls -la /dev/lirc0` should show `crw-rw-rw-` or similar.

**2. Start pibot after the device exists**  
`compose-up.sh` automatically waits up to 30 seconds for the LIRC device (from your override) to exist and be readable before starting the pibot container. So if udev creates `/dev/lirc0` a few seconds after boot, the container will start with the device available. If the device never appears (e.g. dongle unplugged or bound to usbhid), the script warns and starts anyway so the Pi doesn't block.

**3. Dongle bound to HID at boot**  
If the dongle is used as a keyboard (usbhid), `/dev/lirc0` is never created until you unbind and bind mceusb (section 2). To have it always as IR after reboot, add a udev rule or systemd service that runs the unbind/bind commands at boot — see section 6.

**Summary:** Install the udev rule (step 1) and use `./scripts/compose-up.sh pibot -d` (or your normal startup). After reboot, IR blasting should work without manual `chmod`.

## 6. Make binding persistent (optional)

To have the dongle always used as IR (not HID) after reboot, add a udev rule and a script, or use a **modprobe**/udev rule that unbinds from usbhid and loads mceusb. Example udev rule (match by vendor/product, then run a script that does unbind/bind) or a systemd service that runs the unbind/bind commands at boot. Exact rule depends on your distro; the commands in section 2 are the ones to run.

## 7. Troubleshooting

### Nothing flashes when sending / fan doesn’t respond

- **Transmit not cabled:** Run `dmesg | grep "tx ports"`. If it says **`(0x0 cabled)`**, this dongle has **no IR transmitter** — it’s receive-only. Learning works; blasting does not. Use a different USB IR blaster that has tx ports cabled (e.g. some HP/Philips MCE units show `0x1` or `0x3`).

### Fan still doesn’t respond after learning and blasting

If you’ve learned the button, plugged in the emitter, tried 38k/40k/56k and the measured waveform, and the device still does nothing:

- **Confirm the remote is IR:** Point the **device’s remote** at your **phone camera** and press the button. If you **don’t** see a purple/white flicker, the remote is almost certainly **RF**. Many Dyson models (Pure Cool, Link, some TP/DP) use RF remotes; an IR blaster cannot control them. You’d need an RF solution (e.g. Broadlink RM, or control power via a smart plug, or use a different fan with an IR remote).
- **If the remote does flicker (IR):** Try one more re-learn with the remote very close to the dongle, then blast only at 38 kHz and 40 kHz. If it still fails, the device may be picky about timing or repeat pattern; the IR path may not be reliable for this unit.

### Fan/device doesn’t respond (but dongle can transmit)

- **Confirm the remote is IR:** Point the remote at your **phone camera** and press a button. If you see a purple/white flicker, it’s IR. If you see nothing, the remote may be **RF** (radio); many Dyson Link / Pure Cool units use RF and won’t respond to an IR dongle.
- **Carrier frequency:** We send at 38 kHz by default. To see what your remote uses, run (then press the button when prompted):
  ```bash
  ir-ctl -d /dev/lirc0 -r -w -m -1
  ```
  If it reports e.g. `carrier 40000`, resend with: `ir-ctl -d /dev/lirc0 -c 40000 --send=path/to/file.ir`
- **Aim and distance:** IR needs line of sight to the device’s sensor (on Dyson fans it’s on the base). Keep the dongle’s IR LED aimed at the sensor and within a few metres.
- **Re-learn:** If you learned with the remote pointed at the dongle and the fan still doesn’t respond, try learning again with the remote very close to the dongle, then blast again.

## 8. References

- Kernel driver: `drivers/media/rc/mceusb.c` (045e:006d = MCE_GEN1)
- LIRC mode2: `PULSE`/`SPACE` + duration in µs (see `linux/lirc.h`)
