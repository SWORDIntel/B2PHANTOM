# IDRAC7-NEW — `svctag`

Upgrade an iDRAC7 **Express** box to **Enterprise** from the running OS.

No LiveDVD. No legacy BIOS boot. No chroot over your own system. No CentOS 6.

---

# NO MORE BOOTING INTO OLD-ASS CENTOS

## why has nobody fucking done this before

Because every guide on the internet tells you to:

1. download a 1.3 GB **CentOS 6 LiveDVD from 2013**,
2. burn it, boot it, fight GNOME 2 and NetworkManager,
3. `chroot` into a dead userland,
4. run a Python **2.6** script,
5. and hope.

That is four layers of obsolete nonsense for one 7-character NVRAM write.
The write itself is a single Dell SMI call that has been sitting in
`libsmbios_c.so.2` the whole time. Locked behind a Python 2 interpreter that
nobody wants on their machine, yes — but it is just a C function.

So this project calls that C function directly, from a ~10 KB binary, on
whatever distro you already run. `dlopen()` the 2013 library, call
`sysinfo_set_service_tag()`, done. No chroot, because the library only needs
itself; nothing else from 2013 comes along for the ride.

`gcc`, one `dlopen`, one function pointer. That is the entire trick. It took
longer to find the right RPM than to write the code, which is probably why
nobody bothered to package it.

---

## What this actually does

An iDRAC7 license is an **XML file signed for one service tag**. The iDRAC
checks the tag in its license against the tag the host reports, and refuses
the license if they disagree. There is no way around that check:

- iDRAC7 Express has **no remote BIOS config** (that is Enterprise-only), so
  you cannot fix anything from the BMC side;
- Redfish on firmware 2.65 exposes **no license endpoint** at all;
- **SSH/`racadm` is refused on Express** — that is the chicken-and-egg this
  whole exercise exists to break;
- the web UI licensing page is gated behind the very edition you are trying
  to install.

So the only lever is the one thing you *do* control: **the tag the host
reports**. `svctag` writes the license's tag into motherboard NVRAM, the
iDRAC re-latches it at POST, and the license validates.

This is a homelab procedure with a real trade-off, stated plainly:

> You are setting a **duplicate service tag**. Your box will claim to be
> whatever machine the license was originally sold with. Dell warranty,
> support entitlement, and the "downloads for my service tag" catalog will
> all resolve to someone else's server. Never do this to a box under
> warranty or support contract.

## Requirements

- A Dell PowerEdge that uses iDRAC7 (12G: R/T/M 620, 720, 820, and friends).
- Bare metal. This fails in a VM, and fails on WSL — the SMI needs the real
  firmware.
- Root. The SMI write rides Dell's `dcdbas` kernel driver (sysfs), and
  `/dev/mem` is only read (low-memory probe), so kernel lockdown must not be
  in enforcing mode.
- `x86_64`. The vendored library is el6 x86_64.
- The license XML, signed for the tag you are going to write.

## Quick start

```bash
cd /home/john/Documents/Github/IDRAC7-NEW

./scripts/build.sh                  # installs missing deps, fetches libsmbios,
                                    # compiles ./svctag
sudo ./scripts/healthcheck.sh       # read-only: proves every precondition
sudo ./scripts/unlock.sh            # backs up the tag, writes the new one

# then follow the printed steps: reboot so the iDRAC re-latches,
# and import licenses/License.xml in the web UI.
```

`unlock.sh` **refuses to write** unless `healthcheck.sh` passes, the license
is signed (`dsig:Signature`), and the target tag matches the license tag.

Useful flags:

```bash
sudo ./scripts/unlock.sh --dry-run            # plan only, writes nothing
sudo ./scripts/unlock.sh --yes                # no prompts
sudo ./scripts/unlock.sh --force              # ignore healthcheck failures
sudo ./scripts/unlock.sh --skip-idrac-reset   # leave the BMC alone
./scripts/build.sh --check-deps               # report deps, change nothing
./scripts/build.sh --no-deps                  # never run the package manager
```

## How it works

### The tag write

The service tag lives in SMM-protected NVRAM on the mainboard. Dell's
firmware exposes a write path through an SMI call, implemented in
`libsmbios_c`. `svctag` does not link against it, it `dlopen()`s it:

```
svctag (built here)  ->  vendor/usr/lib64/libsmbios_c.so.2  ->  SMI  ->  NVRAM
                          (extracted from Dell's el6 RPM, never installed)
```

Strace proves the actual kernel path (this is not guessed):

```
write smi_data            <- 52-byte command buffer: "SMI1" + "BSI1" + port
                             0xB2 + token payload containing the new tag
write smi_data_buf_size   <- buffer length
write smi_request         <- fires the SMI, polls for completion
        ...all under /sys/devices/platform/dcdbas/

open /dev/mem O_RDONLY x~7400  <- probe side: locating the SMBIOS/token
                                 structures in low physical memory
```

The write never touches `/dev/mem` for output — it goes through **`dcdbas`,
Dell's in-kernel Systems Management Base Driver** (GPL, by Dell, ships in the
mainline kernel, auto-loads on Dell DMI matches). That is also why this works
with `CONFIG_STRICT_DEVMEM` enabled: `/dev/mem` is only *read* below the 1 MB
line, which strict mode still allows, and the privileged write is delegated
to the kernel driver.

Three details make this work and are the whole reason the project exists:

1. **The setter is only in the old build.** Upstream libsmbios later dropped
   `sysinfo_set_service_tag`. `build.sh` refuses to continue if the symbol is
   missing, so you cannot silently end up with a read-only library.
2. **The library is vendored, not installed.** The RPMs are extracted into
   `vendor/` with `rpm2cpio`/`cpio`. Nothing is written to `/usr/lib`, nothing
   is added to your package database, and no CentOS userland appears.
3. **No chroot is needed.** The library is self-contained; only glibc is
   external, and a 2013 glibc-linked `.so` loads fine on a modern one for
   these symbols. This is what removes the LiveDVD from the picture entirely.

### The iDRAC side

The write is authoritative in NVRAM immediately, but two caches lag:

| Observer | When it updates | Notes |
| --- | --- | --- |
| `svctag get` (libsmbios/SMI) | instantly | this is the real value |
| `dmidecode` (DMI/SMBIOS) | next boot | populated by BIOS at POST |
| iDRAC (`GET /redfish/v1/Systems/...` → `SKU`) | next POST | a BMC cold reset usually does **not** refresh it |

If a warm reboot does not refresh the iDRAC's view, power off and **pull the
power cords for ~30 s** to drop the standby rail. That always clears it.

Then import the license: **iDRAC Settings → Licenses → Import**, selecting the
XML itself (not a zip, not a `.lic` wrapper). A rejection naming a tag
mismatch means the host has not POSTed with the new tag yet.

### Postboot automation (no clicking at all)

`setup-onboot.sh` installs a **one-shot** systemd user unit that handles the
import after the latch reboot:

```bash
./scripts/setup-onboot.sh          # arm the job; fires on the NEXT boot
sudo systemctl reboot              # go
```

~60 s after your desktop session loads, an `xterm` window opens and runs
`postboot-check.sh`, which:

1. polls the iDRAC's service tag over **Redfish** (`SKU` field) every 30 s
   for up to ~10 min until it matches the license's tag,
2. fires **WSMAN `ImportLicense`** (`DCIM_LicenseManagementService`, proven
   live: `LicenseFile` = base64 XML, `FQDD` = `iDRAC.Embedded.1`,
   `ImportOptions` = 1) once the tag has latched,
3. prints the result, keeps the window open 30 s, writes
   `logs/postboot-*.log`, and **disables and deletes itself** — the next
   boot is clean.

Why WSMAN and not Redfish: iDRAC7 firmware 2.65 has *no* Redfish license
endpoint (`/Licenses` → 400, `/LicenseService` → 400, Manager children →
404). The WSMAN method works even on Express — verified by the
`LIC008 binding mismatch` rejection it returns while the tag is still the
old one, which is exactly the retry condition the job waits out.

If the job gives up (still `LIC008` after ~10 min), power off, pull both
power cords for ~30 s, boot, and run `scripts/postboot-check.sh` by hand —
or pass `--linger` to `setup-onboot.sh` so the job survives a headless boot.

## Configuration

`config/idrac7.conf` (start from `config/idrac7.conf.example`, then
`chmod 600`):

| Key | Default | Meaning |
| --- | --- | --- |
| `LICENSE_XML` | `licenses/License.xml` | the signed license; its tag is the target |
| `NEW_SERVICE_TAG` | *(unset)* | override the target tag explicitly |
| `IDRAC_HOST` | `169.254.0.1` | OS-to-iDRAC address on 12G |
| `IDRAC_USER` / `IDRAC_PASS` | `root` / `calvin` | factory Dell credential; change to match |
| `IPMITOOL` | *(auto)* | pin a specific `ipmitool` binary |
| `IPMI_EXTRA_ARGS` | *(empty)* | e.g. `-I lanplus -H 192.168.1.171` for out-of-band |
| `REBOOT_AFTER` | `ask` | `ask` \| `yes` \| `no` |
| `IDRAC_RESET` | `cold` | `cold` \| `warm` \| `none` |
| `IDRAC_RESET_WAIT` | `240` | seconds to wait for the BMC to answer |
| `STRICT_TAG_MATCH` | `yes` | refuse if target tag != license tag |
| `POSTBOOT_DELAY` | `60` | seconds after desktop load before first probe |
| `POSTBOOT_RETRIES` | `20` | retries, ~30s apart, before the job gives up |

The example file ships the **factory default** `root`/`calvin`. This
workstation's T420 uses `john`/`1786` and its `config/idrac7.conf` is set
accordingly — the example is meant to be portable, so do not be surprised
when the two differ.

## Files

```
IDRAC7-NEW/
├── setup.sh                   orchestrator: build → healthcheck → unlock → onboot
├── svctag                     compiled binary (from build.sh)
├── src/svctag.c               the whole tool: dlopen + get/set service tag
├── scripts/
│   ├── build.sh               deps -> fetch RPMs -> symbol check -> compile
│   ├── common.sh              shared helpers (config, logging, probes)
│   ├── healthcheck.sh         read-only precondition gate, 19 checks
│   ├── unlock.sh              backup -> write -> iDRAC reset -> verify
│   ├── setup-onboot.sh        install the one-shot postboot job
│   ├── postboot-check.sh      postboot runner: wait for latch, import, self-remove
│   └── import-license.py      WSMAN ImportLicense client (Redfish tag check)
├── config/
│   ├── idrac7.conf.example    portable defaults
│   └── idrac7.conf            local, mode 600, git-ignored
├── licenses/License.xml       the signed license (tag-locked)
├── vendor/                    extracted el6 libsmbios + RPM cache
├── backups/                   original tag, timestamped
└── logs/
```

Add `config/idrac7.conf`, `vendor/`, `backups/`, and `svctag` to
`.gitignore` — the first holds credentials, the rest are build state.

## Restoring the original tag

Every run with a new tag writes `backups/original-tag-<timestamp>.txt`
before writing. Restore with:

```bash
sudo ./svctag set 3M9M002
```

Setting the tag back to the original drops the license back to Express,
because the license is bound to `9QYZF42`.

## Manual fallback

If you insist on the historically accurate method, the original is:

```bash
# OMSA 7.1 LiveDVD, CentOS 6, ~1.3 GB
smbios-sys-info --service-tag            # read
smbios-sys-info --service-tag --set=TAG  # write
```

That is what `svctag` replaces. The library it needs is the same one:

```
https://linux.dell.com/repo/hardware/Linux_Repository_14.04.00/
        platform_independent/rh60_64/firmware-tools/
  libsmbios-2.2.27-4.12.1.el6.x86_64.rpm
  smbios-utils-bin-2.2.27-4.12.1.el6.x86_64.rpm
```

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `dlopen failed` | run `./scripts/build.sh`; the vendored `.so` is missing |
| `lacks sysinfo_set_service_tag` | wrong libsmbios — you need Dell's 2.2.27 el6 build |
| `firmware read needs root` | `sudo`; SMI access needs root |
| write returns 0 but tag unchanged | kernel lockdown / VM / WSL — must be bare metal |
| healthcheck: `dcdbas driver` missing | `modprobe dcdbas`; it auto-loads on Dell DMI |
| healthcheck: `/dev/mem` not readable | check `dmesg \| grep -i lock`; disable lockdown |
| iDRAC still shows the old tag | host has not POSTed; reboot, then pull power cords |
| license rejected, tag mismatch | iDRAC has not re-latched; see above |
| `get_service_tag` returns garbage | not a Dell, or a VM faking SMBIOS |

## Verified on

| | |
| --- | --- |
| Host | Dell PowerEdge T420, BIOS 2.9.0, bare metal |
| OS | Debian 13 (trixie), gcc 16.1 |
| BMC | iDRAC7 Express, firmware 2.65 |
| Write | `3M9M002` → `9QYZF42`, `rc=0`, read-back confirmed |
| Post-write | `svctag get` = `9QYZF42`; DMI and iDRAC lagged until POST |

## Credit

The service-tag-vs-license approach and the license XML layout come from
[tnweaver/Dell-iDRAC-7-Enterprise-Steps](https://github.com/tnweaver/Dell-iDRAC-7-Enterprise-Steps).
That repo carries the LiveDVD procedure; this one carries the ten-line
version of the same operation. The library is Dell's, redistributed only as
extracted files inside `vendor/`.

## License

The code here: do what you want. The Dell library and the license XML are
not mine to license — see Dell's terms and the original repo.
