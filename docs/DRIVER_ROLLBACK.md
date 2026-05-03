# NVIDIA Driver Rollback Guide (Linux Mint 22.3 / Cinnamon)

A defensive guide for **before** you upgrade the NVIDIA driver and **after**, if Cinnamon refuses to start.

The strategy: take a snapshot, install the new driver, and if anything breaks have three independent ways to get back to a working desktop.

Currently installed: `nvidia-driver-535` (535.288.01). Target: `nvidia-driver-560` (required by CUDA 12.6).

---

## 1. Before you upgrade — make recovery cheap

These five minutes of prep make the difference between "annoying afternoon" and "reinstall the OS."

### 1.1 Take a Timeshift snapshot

Mint ships **Timeshift** by default and it's the single best safety net.

GUI: **Menu → Timeshift → Create**. Pick *RSYNC* mode if it's the first time. Wait for "Snapshot complete."

CLI:
```bash
sudo timeshift --create --comments "before nvidia 560 upgrade" --tags D
sudo timeshift --list
```

Snapshots include the entire root filesystem (excluding `/home` by default), which is exactly what you need to roll back driver packages, kernel modules, and Xorg config.

### 1.2 Record your current state

```bash
nvidia-smi --query-gpu=driver_version --format=csv,noheader > ~/driver-before.txt
dpkg -l | grep -E 'nvidia|libnvidia' > ~/nvidia-packages-before.txt
uname -r > ~/kernel-before.txt
cat /etc/X11/xorg.conf 2>/dev/null > ~/xorg-conf-before.txt
```

If anything goes sideways you have an exact list of what was installed.

### 1.3 Have a way back to a TTY ready

Memorize: **`Ctrl + Alt + F3`** switches from the graphical session to a text console (TTY3). **`Ctrl + Alt + F2`** typically takes you back to the graphical session if it's still running.

That console works even when Cinnamon is broken, as long as the kernel booted.

### 1.4 (Optional but recommended) Make a Mint live USB

Burn the same Mint 22.3 ISO you installed from to a USB stick. If even the TTY won't come up, you boot the live session and recover from there.

---

## 2. Install the new driver

Two options — both go through `apt`, but Mint's GUI is gentler.

### 2.1 GUI: Driver Manager

**Menu → Administration → Driver Manager**. Wait for it to scan, pick `nvidia-driver-560 (recommended)`, **Apply Changes**, reboot.

### 2.2 CLI

```bash
sudo apt update
sudo apt install nvidia-driver-560
sudo reboot
```

After reboot, **before logging in**, switch to a TTY (`Ctrl+Alt+F3`) and verify the driver is loaded:

```bash
nvidia-smi | head -3
```

Expected: `Driver Version: 560.xx.xx    CUDA Version: 12.6`. Switch back to the graphical session with `Ctrl+Alt+F2` (or `F7` on some setups) and log in.

---

## 3. If the desktop breaks

### 3.1 Diagnose first

Get to a working terminal — pick the first that works:

| Symptom | First thing to try |
|---|---|
| Black screen, no login | `Ctrl+Alt+F3` for a TTY |
| Login loop (returns to login screen after entering password) | `Ctrl+Alt+F3` for a TTY, then read `~/.xsession-errors` |
| Cinnamon falls back to "Software rendering mode" | You're already in — open a terminal |
| Wrong resolution / no acceleration | Already in — open a terminal |
| Even TTY won't come up (just a blinking cursor) | Boot to **recovery mode** (§3.4) |
| Even recovery mode fails | **Live USB** (§3.5) |

### 3.2 Quick check from a TTY

```bash
nvidia-smi                                          # is the driver loaded at all?
journalctl -b -p err                                # boot errors this session
journalctl -u display-manager -b                    # lightdm/gdm log
cat /var/log/Xorg.0.log | grep -i -E "ee|error"     # Xorg errors
```

Common patterns:
- `NVIDIA: Failed to initialize the NVIDIA kernel module` → kernel module didn't build for current kernel; see §3.3
- `Module nvidia not found` → driver install incomplete
- `(EE) NVIDIA(0): Failed to initialize the GPU` → driver/hardware mismatch

### 3.3 Try a clean kernel-module rebuild before rolling back

Sometimes the install just didn't finish (DKMS build failed silently). Rebuild before reverting:

```bash
sudo dpkg --configure -a
sudo apt --fix-broken install
sudo dkms autoinstall
sudo update-initramfs -u
sudo reboot
```

If `nvidia-smi` works after this — you're done, no rollback needed.

### 3.4 Boot to recovery mode

If you can't reach a TTY at all:

1. Reboot. As soon as the BIOS/UEFI splash clears, hold **`Shift`** (BIOS) or tap **`Esc`** (UEFI) to bring up the GRUB menu.
2. Choose **Advanced options for Linux Mint**.
3. Pick the same kernel version you usually boot, but with **(recovery mode)** in the name.
4. From the recovery menu choose **`network`** (to enable apt) then **`root`** (drop to a root shell).

You now have a writable root shell with networking. Skip ahead to §4.

### 3.5 Boot the live USB

If recovery mode also fails:

1. Boot the Mint 22.3 live USB.
2. Open a terminal in the live session.
3. Identify your root partition:
   ```bash
   lsblk -f
   ```
4. Mount it and chroot:
   ```bash
   sudo mount /dev/nvme0n1p2 /mnt              # adjust to your root partition
   sudo mount --bind /dev  /mnt/dev
   sudo mount --bind /proc /mnt/proc
   sudo mount --bind /sys  /mnt/sys
   sudo mount --bind /run  /mnt/run
   sudo cp /etc/resolv.conf /mnt/etc/resolv.conf
   sudo chroot /mnt
   ```
5. You're now operating on the broken install as if booted into it. Continue at §4.

### 3.6 Worst-case temporary unblock — `nomodeset`

If you need the desktop *now* and don't care about the GPU temporarily, boot with `nomodeset` to disable kernel mode-setting (loads a basic VESA driver):

1. At the GRUB menu, highlight your kernel and press **`e`**.
2. Find the line starting with `linux ...`. Add `nomodeset` at the end.
3. Press **`Ctrl+X`** to boot once with that option (it's not persistent).

Cinnamon will come up with software rendering — slow but usable. Now do the rollback (§4) properly.

---

## 4. Rolling back

Three options, in order of safety. If you got here via Timeshift snapshot, **§4.1 is the simplest and most complete** — it reverses everything the upgrade did, including config changes you might have forgotten about.

### 4.1 Restore your Timeshift snapshot (best)

GUI (from a working desktop):
**Timeshift → select your "before nvidia 560 upgrade" snapshot → Restore**.

CLI (from TTY, recovery mode, or chroot):
```bash
sudo timeshift --list                        # find the snapshot name
sudo timeshift --restore --snapshot 'YYYY-MM-DD_HH-MM-SS' --target /dev/nvme0n1p2
sudo reboot
```

Timeshift will reinstate the entire root filesystem to that snapshot, then re-run GRUB. Driver, kernel modules, package state, Xorg config — all back to exactly how they were.

This is by far the lowest-risk option.

### 4.2 Reinstall the previous driver via apt

Skip this if §4.1 worked. Only useful if you didn't take a snapshot or want a more surgical fix.

```bash
# Remove every NVIDIA package the new driver pulled in
sudo apt purge '^nvidia-' '^libnvidia-'
sudo apt autoremove --purge

# Reinstall the version you came from
sudo apt update
sudo apt install nvidia-driver-535

# Rebuild kernel modules and the initramfs
sudo dkms autoinstall
sudo update-initramfs -u
sudo reboot
```

After reboot, verify:
```bash
nvidia-smi | head -3                         # should show 535.xxx
```

If apt complains it can't find `nvidia-driver-535`, you may need to re-enable the right component in `/etc/apt/sources.list.d/` (the official Ubuntu archive — not a PPA — ships the `-535`, `-550`, `-560` packages).

### 4.3 Last resort — fall back to the open-source `nouveau` driver

`nouveau` is the open-source NVIDIA driver. It's slow, has no CUDA support, but it'll always give you a working desktop.

```bash
sudo apt purge '^nvidia-' '^libnvidia-'
sudo apt autoremove --purge

# nouveau is built into the kernel; just remove the blacklist NVIDIA installs
sudo rm -f /etc/modprobe.d/blacklist-nouveau.conf
sudo rm -f /etc/modprobe.d/nvidia-graphics-drivers.conf

sudo update-initramfs -u
sudo reboot
```

Cinnamon will come up using nouveau. CUDA won't work, but you have a usable system to fix things from.

---

## 5. After a successful rollback — pin the version

Once you're back on `nvidia-driver-535`, tell apt **not** to upgrade it next time you run `apt upgrade`:

```bash
sudo apt-mark hold nvidia-driver-535
sudo apt-mark hold libnvidia-common-535
```

To list current holds:
```bash
apt-mark showhold
```

To release later (when you're ready to try again):
```bash
sudo apt-mark unhold nvidia-driver-535
sudo apt-mark unhold libnvidia-common-535
```

---

## 6. Common failure modes — quick reference

| Symptom | Likely cause | Fix |
|---|---|---|
| Black screen, GPU fan spins up | Driver loaded but X failed to init | TTY → check `/var/log/Xorg.0.log` → §4.1 |
| Login loop | Wayland/Xorg auth or compositor issue | TTY → log in → check `~/.xsession-errors` → switch from Wayland to Xorg in lightdm |
| `nvidia-smi: command not found` | Driver package not installed / not on PATH | `sudo apt install nvidia-utils-535` |
| `nvidia-smi: Failed to initialize NVML: Driver/library version mismatch` | New driver installed but old kernel module still loaded — **a reboot fixes this** | `sudo reboot` |
| Cinnamon at very low resolution | nouveau loaded instead of nvidia | `lsmod \| grep nvidia` — if empty, the NVIDIA module didn't load; check DKMS build with `sudo dkms status` |
| Tearing or stuttering after upgrade | Compositor/driver interaction | Try `nvidia-settings` → *X Server Display Configuration* → "Force Composition Pipeline" |
| Hangs on shutdown | Known issue with some NVIDIA versions | Add `nvidia.NVreg_PreserveVideoMemoryAllocations=1` to GRUB kernel cmdline |
| External monitors not detected | Driver installed but Xorg config stale | `sudo nvidia-xconfig` and reboot |

---

## 7. The pre-flight checklist (TL;DR)

Before you run `apt install nvidia-driver-560`:

- [ ] Timeshift snapshot taken and listed in `timeshift --list`
- [ ] `nvidia-smi --query-gpu=driver_version --format=csv,noheader` saved to a file
- [ ] `dpkg -l | grep nvidia` saved to a file
- [ ] You know how to reach a TTY (`Ctrl+Alt+F3`)
- [ ] You know how to reach GRUB recovery mode (hold Shift / tap Esc at boot)
- [ ] You have a Mint 22.3 live USB (optional, for the worst case)
- [ ] You're not in the middle of urgent work — give yourself 30 minutes of slack

If all six are checked, the upgrade is genuinely low-risk: the worst plausible outcome is "boot to TTY, restore Timeshift snapshot, reboot, back where I started."
