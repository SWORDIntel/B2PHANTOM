# WSMAN, or: talking to a BMC that only read half the manual

iDRAC7 fw 2.65 is a strange little computer. It has Redfish, but no Redfish
license endpoint. It has SSH, but refuses it while the box is on Express. It
has WSMAN — and WSMAN answers no matter what licence you are on. That is why
`idrac7-wsman.py` exists.

Every method signature here was found by sending a plausible request and
reading the iDRAC's own complaint (`Missing required parameter X`) until it
stopped complaining. No PDF was consulted. The firmware is the spec.

## The commands

| Command | What it does |
| --- | --- |
| `check` | reads Redfish `SKU`; with `--license` also prints the tag the XML binds, and exits `2` while they disagree |
| `import` | `DCIM_LicenseManagementService.ImportLicense`, base64, `ImportOptions=1`; `LIC900` = done, `LIC008` = tag not latched yet |
| `export-license` | writes the installed licence back out by `--entitlement-id` — proof the import actually stuck |
| `export-config` | LCC `ExportSystemConfiguration` to an NFS/CIFS share |
| `export-factory` | LCC `ExportFactoryConfiguration`; the file name must be **bare** (no extension), CIM format |
| `job-status` | reads one `DCIM_LifeCycleJob` by `--job JID_…` |

NFS is `--share-type nfs` (the default); CIFS is `--share-type cifs`. Both
take `--share-ip`, `--share-path` (the export path exactly, no trailing
slash), and `--file-name`. Everything else is TLS and credentials.

## TLS: the certificate from 2011

The factory iDRAC7 certificate is:

- self-signed,
- expired (valid 2011-06-07 → 2021-06-04),
- **RSA-1024**, which OpenSSL 3 refuses outright.

So plain verification cannot work on a stock box, and `--cacert` cannot save
you either — the failure is `EE certificate key too weak` before the chain is
even considered. Disabling verification (`curl -sk`) throws away the only
identity check available, which is how you end up writing a service tag to
somebody else's server.

The answer is pinning the public key. curl enforces `--pinnedpubkey`
*independently* of `-k`, so the pin — not the chain — becomes the trust
anchor:

```bash
# first contact: print the fingerprint, remember the pin
scripts/idrac7-wsman.py check --host 169.254.0.1 --user root \
    --trust-cert --pin-file config/idrac7.pin

# every later run
scripts/idrac7-wsman.py check --host 169.254.0.1 --user root \
    --pin-file config/idrac7.pin
```

| Flag | What it trusts |
| --- | --- |
| *(nothing)* | the system CA store, i.e. it fails on a factory cert |
| `--pinned-pubkey sha256//…` | exactly that key |
| `--pin-cert cert.pem` | the key in a certificate you already hold |
| `--pin-file FILE` | the key recorded in FILE (written by `--trust-cert`) |
| `--cacert ca.pem` | a real chain — needs a valid cert installed in the BMC |
| `--insecure` | nothing; it says so on stderr, in words |

The shell side follows the same policy through `idrac_curl()` in
`scripts/common.sh`, driven by `IDRAC_TLS_PIN` (a `sha256//…` literal or a
file), `IDRAC_TLS_CACERT`, and `IDRAC_TLS_INSECURE`. A broken pin fails the
healthcheck gate; it never degrades to "no pin, carry on".

Pins are per-device. A pin captured from one BMC will — correctly — refuse a
different one with `rc=90`:

```
curl: (90) SSL: public key does not match pinned public key
```

That is the feature working. Two BMCs on one LAN are two pins.

## Credentials: keep them out of `ps`

`--password` still works and prints a warning, because `/proc/<pid>/cmdline`
is world-readable. The better paths:

| Source | Use |
| --- | --- |
| `--password-file FILE` | first line is the password; warns if group/other readable |
| `IDRAC_PASS` | environment, for scripts and the postboot unit |
| terminal prompt | `getpass`, when neither is given and stdin is a TTY |

The secret reaches curl as a config file on **stdin** (`-K -`), never as an
argument:

```python
curl -sS --proto '=https' -K - …   # "user = \"root:calvin\"" on stdin
```

Verified the boring way: ten `/proc/<curl-pid>/cmdline` samples during a live
export, zero hits for the password. `--proto =https` also stops a redirect
from downgrading the connection.

## Exports are asynchronous, and `4096` is not a receipt

`ReturnValue=4096` means *the iDRAC queued a job*. It does not mean a file
exists. The LC returns a job endpoint reference:

```xml
<n1:Job><wsa:EndpointReference>
  <wsman:ResourceURI>http://schemas.dell.com/wbem/wscim/1/cim-schema/2/DCIM_LifeCycleJob</wsman:ResourceURI>
  <wsman:SelectorSet>
    <wsman:Selector Name="InstanceID">JID_951006733750</wsman:Selector>
    <wsman:Selector Name="__cimnamespace">root/dcim</wsman:Selector>
  </wsman:SelectorSet>
</wsa:EndpointReference></n1:Job>
```

Poll it with a plain WS-Transfer `Get` on that URI and selector — no
enumeration session, no `Pull`, no context to expire:

```
JID_951008542095: Running 0% - Exporting Server Configuration Profile.
JID_951008542095: Failed 100% - Unable to copy the Server Configuration Profile to the network share.
```

Terminal states: `Completed` is success; `Failed`, `Completed with Errors`,
`Rejected`, `Cancelled`, `Killed` are not. Anything else keeps polling.

Then the file check, because a completed job is still only the iDRAC's word:
the export commands stat every candidate path *before* submitting the job and
require a **different size or mtime** afterwards — no clock comparison, so a
BMC with a wrong clock cannot fake freshness — plus ≥512 bytes and an XML
head. The file lands, or the exit code says why.

| Exit | Meaning |
| --- | --- |
| `0` | verified: job completed **and** the file is on the share |
| `2` | still running, not inspectable from here, or tag not latched |
| `3` | job failed, or no usable file |
| `4` | usage / configuration error |

`--no-wait` restores the old queue-and-forget behaviour and prints
`export NOT verified`, which is at least honest.

`job-status --job JID_…` reads any job later, including ones queued by
something else:

```bash
scripts/idrac7-wsman.py job-status --host 169.254.0.1 --user root \
    --job JID_941383795641 --pin-file config/idrac7.pin
```

## Proving the happy path without a cooperating BMC

The box that motivated all this is still on Express, so a real export cannot
succeed yet ([why](troubleshooting.md#sys045-the-export-that-wasnt)). Rather
than ship an unexercised `exit 0`, the client was run against a mock endpoint
that replays the exact XML captured from fw 2.65 — real TLS, real pin, real
curl, real parsing:

```
ExportSystemConfiguration: ReturnValue=4096 []
job JID_MOCK01 queued - waiting up to 60s
  JID_MOCK01: Running 40% - Exporting Server Configuration Profile.
  JID_MOCK01: Completed 100% - Job completed successfully.
verified          : /tmp/mockshare/mock.xml (722 bytes, …)     exit=0
```

The failure branches were exercised the same way: file never appears (`3`),
share not mounted here (`2`), plus live `rc=60`, `rc=90`, and a real
`SYS045` from the hardware.

## Method notes, for the next person

- `DCIM_LifeCycleJob` (capital C) is the URI the iDRAC hands back; plain
  `DCIM_LifecycleJob` is what a hand-written Get accepts. Both work; the
  code uses whichever it was given.
- The lifecycle log is `DCIM_LCLogEntry` (1024 entries, `RecordID`, no
  `Created` field on this firmware — it is `CreationTimeStamp`, offset
  `-360`). `DCIM_LifecycleLog` does not exist here; the fault is
  `Class not found`, which is the iDRAC's way of saying "nice guess".
- `DCIM_LCService.GetRemoteServicesAPIStatus` → `LC061 … is ready` before
  submitting work. Cheap, and it rules out "the LC was busy".
- Attribute writes take `Target`, not `FQDD`, and the canonical name is the
  instance ID form (`iDRAC.Embedded.1#NTPConfigGroup.1#NTP1`). The
  enumeration's `AttributeName` is a display key and will be rejected.
