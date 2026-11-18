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
| `idrac7-wsman.py` | remote WSMAN client: check / import / export-license / export-config / export-factory |
| `reset-playbook.sh` | preflight + post-wipe restore over the host's KCS interface |

### Remote control (WSMAN) - no console, no chroot

iDRAC7 fw 2.65 has no Redfish license endpoint and refuses SSH on Express,
but its WSMAN stack answers remotely. `idrac7-wsman.py` drives it from any
machine that can reach the BMC:

```bash
# does the BMC see the tag the license binds to?
scripts/idrac7-wsman.py check --host 192.168.1.171 --user root --password <pw> \
    --license licenses/License.xml

# import the license (succeeds with LIC900 once the tag has latched)
scripts/idrac7-wsman.py import --host 192.168.1.171 --user root --password <pw> \
    --license licenses/License.xml

# export the installed license back out (proof + backup)
scripts/idrac7-wsman.py export-license --host 192.168.1.171 --user root \
    --password <pw> --entitlement-id DE00000009660549 --out backup.xml

# full LCC config export to an NFS share (the pre-reset backup)
scripts/idrac7-wsman.py export-config --host 192.168.1.171 --user root \
    --password <pw> --share-ip 192.168.1.91 --share-path /srv/idrac-export \
    --file-name t320-idrac-config.xml

# factory baseline export (bare file name, CIM format)
scripts/idrac7-wsman.py export-factory --host 192.168.1.171 --user root \
    --password <pw> --share-ip 192.168.1.91 --share-path /srv/idrac-export \
    --file-name factory
```

All method signatures above were discovered live by iterating the iDRAC's
own `Missing required parameter X` errors - no docs were trusted.

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
`IDRAC_PASS`, `LICENSE_XML`, `IPMITOOL`, `IPMI_EXTRA_ARGS`, `IDRAC_RESET`,
`POSTBOOT_DELAY`, `POSTBOOT_RETRIES`.

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
├── scripts/import-license.py  WSMAN import client
├── config/idrac7.conf.example
├── licenses/License.xml
└── vendor/ backups/ logs/     all gitignored
```

## troubleshooting

| Symptom | Fix |
| --- | --- |
| `lacks sysinfo_set_service_tag` | wrong libsmbios — build.sh refuses; it needs Dell's el6 2.2.27 |
| write rc=0, tag unchanged | VM / WSL / kernel lockdown — must be bare metal |
| healthcheck: `dcdbas` missing | `modprobe dcdbas` |
| iDRAC still shows old tag | no POST since the write; reboot, then pull power cords |
| import says `LIC008` | binding mismatch — tag not latched yet; the postboot job retries ~10 min |

## verified on

Dell PowerEdge T420, BIOS 2.9.0, Debian 13, gcc 16 — iDRAC7 Express fw
2.65. Tag `3M9M002 → 9QYZF42`, `rc=0`, read-back confirmed; WSMAN import
call validated live (returns `LIC008` until POST). Naming credit for
B2PHANTOM goes to a model with taste in firmware puns; the license approach
and XML come from [tnweaver/Dell-iDRAC-7-Enterprise-Steps](https://github.com/tnweaver/Dell-iDRAC-7-Enterprise-Steps).
