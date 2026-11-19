# Troubleshooting, or: the iDRAC is lying, here is how to make it talk

Most iDRAC failures present as one polite sentence and no cause. This file is
the long version of the README table: what each symptom means, how it was
established, and which knob actually moves.

## The table

| Symptom | What it means | Fix |
| --- | --- | --- |
| `lacks sysinfo_set_service_tag` | the wrong libsmbios — the setter symbol is not in it | `build.sh` refuses on purpose; it needs Dell's el6 2.2.27 |
| write `rc=0`, tag unchanged | the SMI went nowhere: VM, WSL, or kernel lockdown | must be bare metal with `dcdbas` loaded |
| healthcheck: `dcdbas` missing | module not loaded | `modprobe dcdbas` |
| iDRAC still shows the old tag | no POST since the write; `dmidecode` updates at POST, Redfish `SKU` too | reboot; if a warm reboot does not latch it, pull both power cords ~30 s |
| import says `LIC008` | the licence binds a tag the BMC does not believe yet | wait for POST; `postboot-check.sh` retries ~10 min |
| `curl: (60) … key too weak` | factory cert is RSA-1024 (and expired in 2021) | pin it: `--trust-cert --pin-file`, or `IDRAC_TLS_PIN` |
| `curl: (90) … does not match pinned public key` | a different BMC, or the cert was replaced | re-capture the pin; pins are per-device |
| export job `SYS045` | the LC never reached the network — see below | check `DCIM_License.LicenseDescription` first |
| export `ReturnValue=4096` then silence | `4096` is *queued*, not copied | `job-status --job JID_…` |
| `LC062 … operation is already running` | one profile operation at a time, per BMC | wait for the previous job, then retry |

## SYS045: the export that wasn't

The reported message is wonderfully vague:

```
JID_951008542095: Failed 100% - Unable to copy the Server Configuration
Profile to the network share. [SYS045]
```

The obvious suspects — NFS permissions, root squash, the share not existing,
the BMC not being able to route — are *all* the wrong question, because the
Lifecycle Controller never got as far as the network. Four pieces of
evidence, in the order they were collected:

**1. The lifecycle log has no error in it.** `DCIM_LCLogEntry` records
`SYS057 "Exporting Server Configuration Profile."` at the start of each job
and then nothing — no mount failure, no permission failure, no internal
error:

```
2754 20261119091731 SYS057 :: Exporting Server Configuration Profile.
2757 20261119091808 SYS057 :: Exporting Server Configuration Profile.
2760 20261119091837 SYS057 :: Exporting Server Configuration Profile.
```

**2. The LC was ready.** `DCIM_LCService.GetRemoteServicesAPIStatus` returns
`Status 0, LCStatus 0, LC061 "…is ready"`. Not a busy-LC problem.

**3. A share that does not exist fails exactly the same way, at the same
speed.** Exporting to `192.168.1.222` (nothing there) and to a live, exported,
`insecure`, `no_root_squash` NFS share produce byte-identical behaviour:

```
job JID_951022773551 queued
  Running 0%  ->  Failed 100%   [SYS045]        real 10.8s
```

If the BMC were failing to *reach* the share, an unreachable IP would take
longer (ARP, retries). It does not. The decision happens before any transfer.

**4. No packets leave the BMC.** Captures on the receiving interface during
live exports show nothing from the BMC — while the same capture happily shows
its ICMP replies, so the capture point is not blind.

Conclusion: the export is gated on capability, not connectivity. And the
licence says which one:

```
DCIM_License.LicenseDescription : iDRAC7 Express License
EntitlementID                   : FD00000001813221
```

Server Configuration Profile export to a **network share** is an Enterprise
capability. This BMC is on Express, and the Enterprise licence cannot be
imported yet because the tag has not latched:

```
iDRAC service tag : 3M9M002
tag not latched yet (3M9M002) - host has not POSTed with 9QYZF42
```

So the order of operations is the whole fix:

```bash
sudo systemctl reboot                     # BIOS populates SMBIOS at POST
# the iDRAC latches 9QYZF42, then:
IDRAC_PASS=… scripts/idrac7-wsman.py import --host 169.254.0.1 \
    --user root --license licenses/License.xml --tag 9QYZF42 \
    --pin-file config/idrac7.pin
IDRAC_PASS=… scripts/idrac7-wsman.py export-config --host 169.254.0.1 \
    --user root --share-ip 192.168.1.91 --share-path /srv/idrac-export \
    --file-name t320-idrac-config.xml --pin-file config/idrac7.pin
```

Expected on success: `verified : /srv/idrac-export/… (N bytes, …)`, exit `0`.

### If it is licensed and it still fails

Then it really is the share, and the usual causes are:

- NFSv3 over **UDP**: the 12G NFS client is old. Modern `nfsd` may listen on
  TCP only. `rpcinfo -T udp <server> nfs 3` should say `ready and waiting`;
  if it says `Program not registered`, set `[nfsd] udp=y` in `/etc/nfs.conf`
  and restart `nfs-server`.
- The export line needs `insecure` (the BMC uses a high source port) and
  `no_root_squash`.
- The BMC's IP must be inside the exported subnet, and `ShareName` must be
  the export path exactly (`/srv/idrac-export`, not a subdirectory, no
  trailing slash).
- An incorrect share name on 2.65 can wedge the LC (Dell's own 2.65 release
  notes warn about a loop). If jobs stop draining, restart the iDRAC and
  re-check `GetRemoteServicesAPIStatus` before trying again.

## TLS, or: why `-sk` was never acceptable

The factory certificate makes normal verification impossible, which pushes
people to `curl -sk` and from there to writing a service tag to whatever
answers on that address. Pinning replaces it without giving up identity:

```bash
scripts/idrac7-wsman.py check --host 169.254.0.1 --user root \
    --trust-cert --pin-file config/idrac7.pin    # capture + print fingerprint
scripts/idrac7-wsman.py check --host 169.254.0.1 --user root \
    --pin-file config/idrac7.pin                 # every run after
```

Details and the full flag table: [wsman.md](wsman.md#tls-the-certificate-from-2011).

## Gathering evidence instead of guessing

```bash
# is the LC alive and idle?
idrac7-wsman.py check --host H --user U --pin-file P     # exits 2 if tag != expected
# what does the LC think happened?
#   DCIM_LCLogEntry  -> the lifecycle log (SYS057, USR0030, …)
#   DCIM_License     -> LicenseDescription: Express or Enterprise
# what is the BMC doing on the wire?
sudo tcpdump -ni <iface> -w /tmp/idrac.pcap 'host <bmc-ip>'   # then read with -r
```

Two habits worth keeping: correlate by `RecordID`/`CreationTimeStamp`, not by
eyeballing the last lines (the enumeration order is not chronological), and
always run a negative control — a deliberately broken target — before
believing a "no traffic" or "no error" observation.
