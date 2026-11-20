# B2PHANTOM

*Ring −2 doesn't need CentOS 6.*

Upgrade an iDRAC7 **Express** box to **Enterprise** from the running OS —
one ~17 KB binary, one `dlopen`, zero LiveDVDs, zero chroots, zero Python 2.

---

## why this exists

Every guide online: download a 1.3 GB CentOS 6 LiveDVD from 2013, boot it,
fight GNOME 2, chroot into a dead userland, run a Python 2.6 script, hope.

The actual operation is one Dell SMI call, sitting in `libsmbios_c.so.2`
the whole time. It was just locked behind 2013. `svctag` calls it directly:

```
svctag (built here) → vendor/libsmbios_c.so.2 → /sys/devices/platform/dcdbas
                        (el6 RPM, extracted,       (Dell's in-kernel driver
                         never installed)            fires the 0xB2 SMI)
```

The SMI write is strace-proven: a 52-byte command buffer — `SMI1` + `BSI1` +
port `0xB2` + the new tag — written to `dcdbas/smi_data`, length to
`dcdbas/smi_data_buf_size`, trigger via `dcdbas/smi_request`. `/dev/mem` is
only *read* (low-memory probe). The firmware trusts a magic string, not a
signature: the SMI is unsigned. The license, by contrast, is RSA-signed —
that asymmetry is the entire trick. You can't forge the license, so you
make the box claim the identity a real signed license already covers.

**The cost, stated plainly:** you set a duplicate service tag. Warranty,
support, and Dell's "downloads for my tag" will resolve to someone else's
server. Never do this to a box under contract.

## quick start

```bash
sudo ./setup.sh          # interactive TUI guide (or run the steps by hand)

# manual path:
./scripts/build.sh                 # deps + fetch libsmbios + compile svctag
sudo ./scripts/healthcheck.sh      # 20-check gate, read-only
sudo ./scripts/unlock.sh           # backup tag -> write -> verify
./scripts/setup-onboot.sh          # arm one-shot postboot job
sudo systemctl reboot              # iDRAC re-latches the tag at POST
```

After the reboot, a terminal pops up ~60 s into the desktop session,
polls the iDRAC's tag over Redfish until it latches, then imports the
license over **WSMAN** (`DCIM_LicenseManagementService.ImportLicense` —
iDRAC7 fw 2.65 has no Redfish license endpoint) and removes itself.

## how the parts fit

| Part | Job |
| --- | --- |
| `svctag` | read/write the service tag via `dlopen`'d libsmbios |
| `build.sh` | auto-installs deps, fetches el6 RPMs, refuses to build if the setter symbol is missing |
| `healthcheck.sh` | root, Dell/12G, `dcdbas` loaded+writable, `/dev/mem` readable, license signed, tag match |
| `unlock.sh` | fails closed on healthcheck; backs up tag to `backups/`, writes, resets iDRAC, verifies |
| `setup-onboot.sh` | one-shot systemd unit: xterm popup → wait for latch → import → self-delete |
| `idrac7-wsman.py` | remote WSMAN client: check / import / export-license / export-config / export-factory / job-status |
| `reset-playbook.sh` | preflight + post-wipe restore over the host's KCS interface |

### Remote control (WSMAN) — no console, no chroot

iDRAC7 fw 2.65 has no Redfish license endpoint and refuses SSH on Express,
but it answers WSMAN — and WSMAN does not care which license you bought.

Credentials stay out of `argv` (`ps` shows it): the client takes
`--password-file`, `IDRAC_PASS`, or a prompt, and hands the secret to curl on
stdin. TLS is *pinned*, not disabled — the factory cert is self-signed,
expired since 2021 and RSA-1024, so normal verification can never succeed:

```bash
export IDRAC_PASS=...

# capture the BMC's public-key pin once; prints the fingerprint
scripts/idrac7-wsman.py check --host 169.254.0.1 --user root \
    --trust-cert --pin-file config/idrac7.pin

# does the BMC see the tag the license binds to? (exit 2 = not yet)
scripts/idrac7-wsman.py check --host 169.254.0.1 --user root \
    --license licenses/License.xml --pin-file config/idrac7.pin

# import the license (LIC900 once the tag has latched)
scripts/idrac7-wsman.py import --host 169.254.0.1 --user root \
    --license licenses/License.xml --pin-file config/idrac7.pin

# full LCC config export to NFS — the pre-reset backup
scripts/idrac7-wsman.py export-config --host 169.254.0.1 --user root \
    --share-ip 192.168.1.91 --share-path /srv/idrac-export \
    --file-name t320-idrac-config.xml --pin-file config/idrac7.pin
```

`ReturnValue=4096` is a promise to do something, not a receipt. The export
commands follow the `DCIM_LifeCycleJob` instance to a terminal state and then
check the file on the share (fresh size/mtime, XML head), so this now exits
`3` instead of grinning at you:

```
ExportSystemConfiguration: ReturnValue=4096 []
job JID_951008542095 queued - waiting up to 90s
  JID_951008542095: Failed 100% - Unable to copy the Server Configuration
  Profile to the network share.
job failed: ... [SYS045]
```

Exit codes: `0` verified, `2` still running / cannot inspect the share,
`3` failed, `4` misuse. `job-status --job JID_…` reads any job later, and
`--no-wait` restores queue-and-forget (it does say `NOT verified`).

→ **[WSMAN in depth](docs/wsman.md)** — TLS pinning, credential handling,
the job state machine, and how the happy path was proven without a
cooperating BMC.
→ **[SYS045, the export that wasn't](docs/troubleshooting.md#sys045-the-export-that-wasnt)** —
four kinds of evidence and one licence gate.

### Factory reset (needs a finger)

iDRAC7 fw 2.65 exposes **no remote factory-reset**: no WSMAN method, no
Redfish action (only `Manager.Reset` = graceful restart), and importing the
LCC factory CIM queues a job that silently changes nothing (verified on a
T320 - a probe setting survived it). The reset itself is physical:

- **A.** hold the front-panel **i-button ~15 s** (12G factory-reset gesture), or
- **B.** pull both power cords ~30 s (power drain; fixes GUI corruption,
  does not reset users).

Everything around it is scripted:

```bash
sudo ./scripts/reset-playbook.sh preflight   # on the host, BEFORE the reset
# ... physical reset happens ...
sudo ./scripts/reset-playbook.sh restore     # on the host, after
```

`restore` uses the host's **KCS** interface (which works even with the BMC's
network wiped): password, channel access, DHCP/static IP, NIC selection,
then prints the license re-import command. Keep the preflight output and a
copy of `export-config` output - that is the restore reference.

Tag visibility after a write:

| Observer | Updates |
| --- | --- |
| `svctag get` | instantly |
| `dmidecode` / DMI | next boot (BIOS populates SMBIOS at POST) |
| iDRAC Redfish `SKU` | next POST; BMC cold reset usually does **not** refresh it |

If a warm reboot doesn't latch it: power off, pull both power cords ~30 s
(drop the standby rail), power back on.

## configuration

Copy `config/idrac7.conf.example` → `config/idrac7.conf`, `chmod 600`.
The example ships factory `root/calvin`; keys: `IDRAC_HOST`, `IDRAC_USER`,
`IDRAC_PASS`, `IDRAC_TLS_PIN`, `IDRAC_TLS_CACERT`, `IDRAC_TLS_INSECURE`,
`LICENSE_XML`, `IPMITOOL`, `IPMI_EXTRA_ARGS`, `IDRAC_RESET`,
`POSTBOOT_DELAY`, `POSTBOOT_RETRIES`. `IDRAC_TLS_PIN` takes either a
`sha256//...` value or a file holding one; leave it empty and the TLS checks
report `TLS not verified` instead of authenticating the BMC. A broken pin
fails the gate — it never quietly degrades to "no pin, carry on".

## restoring

Every write stores the old tag in `backups/` first:

```bash
sudo ./svctag set 3M9M002     # drops the license back to Express
```

## files

```
B2PHANTOM/
├── setup.sh                   TUI guide
├── svctag                     compiled binary (gitignored)
├── src/svctag.c               dlopen + get/set, ~300 lines
├── scripts/{build,common,healthcheck,unlock,setup-onboot,postboot-check}.sh
├── scripts/idrac7-wsman.py    remote WSMAN client (docs/wsman.md)
├── scripts/import-license.py  thin wrapper kept for postboot-check.sh
├── docs/{wsman,troubleshooting}.md
├── config/idrac7.conf.example
├── licenses/License.xml
└── vendor/ backups/ logs/     all gitignored
```

## troubleshooting

| Symptom | Fix |
| --- | --- |
| `lacks sysinfo_set_service_tag` | wrong libsmbios — build.sh refuses; it needs Dell's el6 2.2.27 |
| write rc=0, tag unchanged | VM / WSL / kernel lockdown — must be bare metal |
| iDRAC still shows old tag | no POST since the write; reboot, then pull power cords |
| import says `LIC008` | binding mismatch — tag not latched yet; the postboot job retries ~10 min |
| postboot log: `xterm: DISPLAY is not set` | display race — rerun `postboot-terminal.sh` or import manually |

### The POST warning after a tag change (normal, no bypass button)

On the first boot after the tag write, the 12G Lifecycle Controller may
stop POST with a plain message like *"this license doesn't support
motherboard swap"* and no visible way past it. The system has not broken:
the LCC is reacting to the changed service tag as if the motherboard were
swapped, and without an LCC entitlement it just complains. Power through it
(a keystroke or timeout clears it; if truly stuck, power off/on once) and
continue booting. The warning stops once the iDRAC re-latches the new tag
and the license imports.

### Known firmware-level limit (2.65.65.65)

On both fleet boxes the web GUI (`/start.html` 404) and SSH password logins
fail for *every* account with or without the Enterprise license, before and
after a same-version reflash. There is no remote factory-reset on this
firmware (no WSMAN method, no Redfish action, no F2 option, i-button
gesture unreliable), so treat GUI+SSH as unavailable and drive the BMC via
Redfish/WSMAN/IPMI - everything in this repo does exactly that.
| curl rc=60 / `key too weak` | factory RSA-1024 cert — pin it (`--trust-cert --pin-file`) |
| curl rc=90 | pinned key changed — different BMC or new cert; re-capture |
| export `SYS045` | the LC never reached the network; check `DCIM_License` — network-share SCP export wants Enterprise |
| export `4096` then silence | `4096` is *queued*; `job-status --job JID_…` |

→ **[the long version](docs/troubleshooting.md)** — every symptom with its
diagnosis, how each conclusion was established, and the one-line commands
that produce the evidence.

## verified on

Dell PowerEdge T420, BIOS 2.9.0, Debian 13, gcc 16 — iDRAC7 Express fw
2.65. Tag `3M9M002 → 9QYZF42`, `rc=0`, read-back confirmed; WSMAN import
call validated live (returns `LIC008` until POST); export jobs followed
live to `SYS045`; the verified-success path exercised end to end against a
replay of the captured fw 2.65 XML (the hardware is still on Express,
awaiting its POST). Naming credit for B2PHANTOM goes to a model with taste
in firmware puns; the license approach and XML come from
[tnweaver/Dell-iDRAC-7-Enterprise-Steps](https://github.com/tnweaver/Dell-iDRAC-7-Enterprise-Steps).
