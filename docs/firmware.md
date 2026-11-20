# Inside `firmimg.d7` — and why it can't be patched

Notes from taking the iDRAC7 firmware apart: what's in it, how it's signed,
what the update verifier actually checks, and the tooling that got there.
Everything below was reproduced locally against the 2.65.65.65 image; no
claim here is from a datasheet.

**Short version:** the image is signed by Dell with a DSA key whose private
half is not in the image, the verifier correctly rejects unverified packages,
and patching is therefore closed — not because the trust root is strong (it's
a keyring in a writable filesystem) but because the code checks its own flags.

## Layout

`firmimg.d7` (112 384 230 bytes) is a container, not a single filesystem:

| Offset | Size | Contents |
| --- | --- | --- |
| `0x000200` | — | uImage, SuperH, gzip — the BMC kernel (`sh-linux`) |
| `0x2F0C00` | 107.5 MB | SquashFS 4.0 rootfs — 7781 inodes, ~7.5 MB extracted |
| `0x69B9470` | — | signature area / padding |
| `0x69F4800` | 1.3 MB | SquashFS — **factory data partition**, 767 inodes |
| `0x6B2D800` | 227 B | **PGP signature** (ASCII armour) over bytes `0..0x6B2D800` |

The data partition is not a recovery OS: it holds BMC defaults — `fw_ver`
(`2.65.15.65.65`), `lc_ver` (`2.65.65.65.10`), `network_config`, `ID_devid.log`,
and `ipmi/Sideswipe/*` (per-silicon IPMI blobs, `NVRAM_FRU00.dat`,
`platcfgfld.txt`, `bmcsetting`). Build date on everything: **21 Feb 2020**.

```bash
binwalk recovery/firmimg.d7
head -c 112384000 recovery/firmimg.d7 > payload.bin        # never dd bs=1 here
dd if=recovery/firmimg.d7 of=root.sqfs bs=1M skip=2 count=106
unsquashfs -o 986112 -d rootfs root.sqfs                    # 0x2F0C00 - 0x200000
dd if=recovery/firmimg.d7 of=rec.sqfs bs=1 skip=111101952 count=1300000
```

## It is signed, and the signature is good

The rootfs ships the keyring the verifier uses:

```
rootfs/etc/gpg/secupkey/.gnupg/pubring.gpg
  dsa1024 2001-04-16  A77951D23B66A9D   Dell, Inc. (Product Group)
  dsa2048 2011-10-17  756BA70B1019CED6  Dell Inc., PGRE 2011 (PG Release Engineering)

secring.gpg -> EMPTY
```

The trailing signature is DSA (`algo 17`), key `756BA70B1019CED6`, created
2020-02-21 10:33:59, and it **verifies**:

```bash
GNUPGHOME=rootfs/etc/gpg/secupkey/.gnupg gpg --verify sig_end.asc payload.bin
  gpg: Signature made Fri 21 Feb 2020 10:33:59 AM GMT
  gpg:                using DSA key 756BA70B1019CED6
  gpg: Good signature from "Dell Inc., PGRE 2011 ..."
```

Consequences, in order of importance:

1. **Any edit to the payload breaks the signature**, and the private key is not
   in the image (`secring.gpg` empty), not in any key corpus on hand, and
   cannot be carried on a YubiKey — the key is **DSA-2048**, while the
   OpenPGP applet implements RSA and ECC only. Signing is not "hard", it is
   impossible without Dell's key.
2. Patching a squashfs and repacking is trivial; producing an image the BMC
   will accept is the entire problem.
3. The trust anchor is nevertheless *shaped* badly: verification terminates in
   `/bin/gpg` plus a keyring directory inside a writable rootfs, not in a
   hardware root of trust.

## What the verifier does

Chain, resolved from the call graph:

```
SUS_process_update  (0x3f6a0)
  -> SUS_verify_and_unzip  (0x2fae0, 2748 B)
       -> SUS_gpg_verify   (0x2ed20, 1268 B)
            -> SUS_exec_program     => /bin/gpg --verify <sig> <pkg>
               keyring: /etc/gpg/secupkey/.gnupg
```

Decompiled contract of `SUS_gpg_verify(p1, p2, p3, p4)`:

```c
if (p4 == 0)          return 0x3f;   /* arg4 NULL                 */
*p4 = 0;
if (check(p1) == 0)   return 0x46;   /* arg1 invalid              */
if (check(p2) == 0)   return 0x4a;   /* arg2 invalid              */
if (check(p3) == 0)   return 0x37;   /* arg3 invalid              */
r = worker(&ctx);                    /* runs gpg                  */
if (r == 0) {
    if (ctx.status == 0) { *p4 = 1; return 0; }   /* verified      */
    return 0;                                     /* unverified    */
}
return 0x4c;                         /* gpg said no               */
```

Two different outcomes both return `0`, separated only by the out-parameter.
That looks like a hole until you read the caller, which is exactly where the
disassembly pays off:

```
0x30074  bsrf  r1                 ; SUS_gpg_verify(p1,p2,p3,&flag)
0x30080  mov   r0,r13             ; capture return
0x30082  tst   r13,r13
0x30084  bt.s  0x30120            ; success -> check the flag
0x30120  mov.b @(r0,r15),r1       ; r1 = flag
0x30122  tst   r1,r1
0x30124  bf    0x30160            ; nonzero -> verified, continue
0x30148  mov   #75,r13            ; 0x4B -> "not verified", return
```

So `SUS_verify_and_unzip` **does** read the flag and converts "succeeded but
unverified" into error `0x4B`. An unsigned package is rejected, not accepted.

### Error codes recovered

| Code | Meaning |
| --- | --- |
| `0x37` (55) | arg3 validation failed |
| `0x3f` (63) | arg4 (out-param) NULL |
| `0x46` (70) | arg1 validation failed |
| `0x4a` (74) | arg2 validation failed |
| `0x4b` (75) | not verified (set by the caller) |
| `0x4c` (76) | verification failed (gpg nonzero) |

### Things that look like bypasses and are not

- **`SUS_allow_unsigned`** (`0x305a0`, 84 B) decompiles to an unconditional
  `return 1`. Nothing in the traced call chain consults it. It is a predicate
  compiled in the "allowed" state that no path reads.
- **`digitalSignature="false" timeout="%s">`** in `liblcl`'s rodata is a
  *format template emitted by `bin/redownloader`* when packaging — the write
  side, not a verification switch. It has no code reference in the verifier,
  and `usr/bin/os` does not contain the string at all.

## Tooling that actually works on this target

| Job | Tool | Note |
| --- | --- | --- |
| unpack | `binwalk`, `unsquashfs -o` | `sasquatch` not needed; stock squashfs-tools reads it |
| disassemble | `binutils-sh4-linux-gnu` | `radare3` rejects 32-bit SH; `r2` decodes but resolves no xrefs; objdump has no SH |
| decompile | Ghidra 12.1.3, `SuperH4:LE:32:default` | image base is `0x10000`, so file offset `0x2ed20` is address `0x3ed20` |
| compile | `gcc-sh4-linux-gnu` (`-m4`) | must link the firmware's own EGLIBC 2.19 or the harness demands `GLIBC_2.34` |
| run firmware code | `qemu-sh4 -L <rootfs>` | runs `usr/bin/os`, `bin/redownloader`; use the rootfs as sysroot |
| debug | `gdb-multiarch` + `qemu-sh4 -g` | works, but code must be reached in its normal environment |

**Ghidra headless on Debian 13 dies on a smartcard provider** (`slotListIndex
is 0 but token only has 0 slots`) because `java.security` lists `SunPKCS11`.
Strip it and point Java at the copy:

```bash
grep -v '^security.provider.12=SunPKCS11' /etc/java-21-openjdk/security/java.security > /tmp/ghidra.security
export JAVA_TOOL_OPTIONS="-Djava.security.properties==/tmp/ghidra.security"
analyzeHeadless /tmp/ghproj b2p -import liblcl.so.1.2.3 \
  -processor 'SuperH4:LE:32:default' -scriptPath /tmp/ghidra_scripts \
  -postScript DecompSUS2.java
```

### Harness caveat

Calling the exported `SUS_gpg_verify` from a stub built with
`gcc-sh4-linux-gnu` and run under `qemu-sh4` **SIGSEGVs** in every argument
configuration: liblcl expects its daemon's logging/GLib/IPMI subsystem to be
initialised, and a `-nostdlib` stub does not provide it. Mechanical
result: the call is reachable, the environment is not. Answering anything
this way needs the real daemon, not a stub.

Methodology note learned the hard way: `prog | head; echo $?` reports *head's*
status. Two rounds of "it returns 0" were this mistake. Capture exit codes
without a pipe.

## Verdict

- The update verifier holds on every path traced: signature root → gpg →
  out-param → caller's `0x4B`.
- Patching the firmware requires Dell's DSA private key. It is not obtainable
  from the image, and not storable on a YubiKey.
- For a wedged Lifecycle Controller, the remedy is a **stock reflash** through
  the web UI (signed image, accepted) plus a standby-rail power drain — not a
  patched image.

If someone wants to continue this: the untraced frame is `SUS_process_update`
at `0x3f6a0` (call site `0x407xx`), and the RSA path in `libvws.so.9.9.9`
(`VerifySignature` @ `0x83e0`, source `verifywinsign.c`) is a separate
mechanism worth its own look.
