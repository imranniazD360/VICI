# Hetzner Rescue — VICIdial 12 without the ViciBox ISO

Hetzner Rescue **does not include ViciBox**. Do not wget the ~2 GB official ISO onto Rescue `/root` (RAM disk). Install **openSUSE Leap** with `installimage`, reboot, then run this repo’s installer.

Also see: [INSTALL.md](INSTALL.md) · [INTERVIEW.md](INTERVIEW.md)

---

## Why not the ISO

| Path | What happens |
| --- | --- |
| ViciBox ISO | ~2 GB from `download.vicidial.com`, slow from Hetzner; Rescue RAM fills (~1.9 GB) → `No space left on device` |
| Hetzner `images/` | Alma, Rocky, Debian, Ubuntu, **OpenSUSE Leap 16** — **no ViciBox** |
| This installer | Leap 15.6 or 16.0 + packages + source = ViciBox 12–equivalent stack |

`installimage` custom images are **tar** archives of Debian/Ubuntu/Arch/RHEL clones — **not** a `.iso`, **not** OpenSUSE custom tarballs. Leap 16 is already in `/root/images`.

---

## Rescue → Leap 16 (do this)

Prompt must be `root@rescue`. One disk, `SWRAID 0`. Pick **amd64** (not arm64).

```bash
ls /root/images/ | grep -i suse
# Use: Opensuse-1600-amd64-base.tar.zst

installimage
```

Editor:

- `DRIVE1 /dev/sda` (or the disk `lsblk` shows)
- `SWRAID 0`
- `HOSTNAME` e.g. `vici12`
- `IMAGE` = `/root/images/Opensuse-1600-amd64-base.tar.zst`

Save: **F10** or **Esc** then **0**. After install:

```bash
reboot
```

SSH again. Prompt must **not** be `root@rescue`. Then:

```bash
zypper ref && zypper up && reboot
```

```bash
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
chmod +x install-vicidial12-opensuse.sh

./install-vicidial12-opensuse.sh detect
./install-vicidial12-opensuse.sh check
./install-vicidial12-opensuse.sh install \
  --role express --yes --stop-conflicts \
  --server-ip YOUR.PUBLIC.IP \
  --public-ip YOUR.PUBLIC.IP
./install-vicidial12-opensuse.sh setup --yes
reboot
screen -ls && asterisk -r
```

Do **not** use `--lab` on 8 CPU / 16 GB. Disk ~305 GiB may **WARN** vs 500 GB recommended; that is OK if ≥ 160 GB.

If Rescue wget already failed:

```bash
rm -f /root/ViciBox_V12.x86_64-12.0.2.iso
df -h /
```

---

## Official ISO links (slow — skip on Rescue)

Directory: https://download.vicidial.com/iso/vicibox/server/

- Standard (one disk): https://download.vicidial.com/iso/vicibox/server/ViciBox_V12.x86_64-12.0.2.iso
- MD RAID (two disks): https://download.vicidial.com/iso/vicibox/server/ViciBox_V12.x86_64-12.0.2-md.iso
- Docs: https://docs.vicibox.com/en/latest/installation/media/media-std.html

There is **no official faster mirror**.

---

## Custom image / ISO on Hetzner (if you insist)

Uploading a file to Rescue **does not** make `installimage` install it as an OS.

| Method | Use | Notes |
| --- | --- | --- |
| `installimage` → **custom_images** | `.tar.gz` / `.tar.zst` of Debian/Ubuntu/Arch/RHEL | Not ViciBox ISO; not OpenSUSE |
| Robot **KVM** | Real bootable ISO | [Custom images](https://docs.hetzner.com/robot/dedicated-server/operating-systems/installing-custom-images/) · [KVM](https://docs.hetzner.com/robot/dedicated-server/maintenance/kvm-console/) |
| Cloud ISO attach | Cloud console ISO library | Not the same as SCP into Rescue `/root` |

SCP example (still will not appear in the OS menu as ViciBox):

```bash
scp -i KEY.pem ./ViciBox_V12.x86_64-12.0.2.iso root@SERVER:/root/
```

Rescue `/root` is wiped on reboot. Hetzner docs:

- Rescue: https://docs.hetzner.com/robot/dedicated-server/troubleshooting/hetzner-rescue-system
- installimage: https://docs.hetzner.com/robot/dedicated-server/operating-systems/installimage

---

## After Leap: installer fetch

```bash
curl -fsSL -o install-vicidial12-opensuse.sh \
  https://raw.githubusercontent.com/imranniazD360/VICI/main/install-vicidial12-opensuse.sh
```

Repo: https://github.com/imranniazD360/VICI
