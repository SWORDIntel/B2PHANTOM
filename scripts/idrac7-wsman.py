#!/usr/bin/env python3
"""idrac7-wsman.py - remote iDRAC7 operations over WSMAN (works on Express).

Every operation here was discovered live against iDRAC7 firmware 2.65:
Redfish has NO license endpoint on this firmware, and SSH/racadm is refused
while the box is on Express - WSMAN is the only remote control surface, and
it answers on Express.

Commands:
  check           read the iDRAC's service tag (Redfish SKU), compare to --tag
  import          import a license XML (base64, ImportOptions=1)
  export-license  export the installed license by EntitlementID
  export-config   LCC ExportSystemConfiguration to an NFS/CIFS share
  export-factory  LCC ExportFactoryConfiguration to an NFS/CIFS share
  job-status      read one lifecycle job (JID_...)

TLS: certificate verification is on by default. The factory iDRAC7 cert is
self-signed and expired (2011-2021), so a stock box cannot be validated
against a CA - pin the public key instead. curl's --pinnedpubkey is enforced
independently of -k, so the pin, not the chain, becomes the trust anchor:

  # first contact: print the fingerprint, remember the pin
  idrac7-wsman.py check --host H --user root --trust-cert --pin-file idrac7.pin
  # every later run
  idrac7-wsman.py check --host H --user root --pin-file idrac7.pin

`--pin-cert FILE` derives the pin from a certificate you already hold,
`--cacert` does full chain verification (needs a valid cert in the iDRAC),
and `--insecure` switches verification off and says so on stderr.

Credentials: --password still works but is visible in `ps`; prefer
--password-file, IDRAC_PASS in the environment, or the interactive prompt.
The secret is handed to curl as a config file on stdin (-K -), never on argv.

Jobs: LCC exports are asynchronous - ReturnValue=4096 means the iDRAC queued
the job, not that a file reached the share. The export commands therefore
track the DCIM_LifecycleJob instance to a terminal state and then look for
the file on the share (--verify-path overrides the derived path).

Exit codes: 0 ok, 2 retryable (tag not latched / job still running /
unverified), 3 failed, 4 usage or configuration error.
"""
import argparse
import base64
import getpass
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import uuid

WSMAN = "/wsman"
CIM = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim"
LIC_SVC = f"{CIM}/DCIM_LicenseManagementService"
LC_SVC = f"{CIM}/DCIM_LCService"
JOB_RES = f"{CIM}/DCIM_LifecycleJob"      # the URI a plain Get accepts
ACT_GET = "http://schemas.xmlsoap.org/ws/2004/09/transfer/Get"

# Filled once by configure_tls(): curl flags that carry policy.
TLS_ARGS = []

JOB_OK = {"Completed"}
JOB_BAD = {"Failed", "Completed with Errors", "Rejected", "Cancelled", "Killed"}

CURL_HINTS = {
    6: "DNS resolution failed for the iDRAC host",
    7: "connection refused - is the iDRAC answering on 443?",
    28: "timed out",
    35: "TLS handshake failed",
    60: "TLS certificate verification failed. The factory iDRAC7 cert is "
        "self-signed, expired and RSA-1024 (modern OpenSSL rejects the key), "
        "so pin it (--trust-cert --pin-file FILE), or install a valid "
        "certificate and use --cacert. --insecure disables verification.",
    90: "pinned public key mismatch - the iDRAC presented a different key "
        "than the one pinned (certificate replaced, or the wrong host)",
}


class CurlError(RuntimeError):
    def __init__(self, rc, msg):
        self.rc = rc
        super().__init__(msg)


def die(msg, code=4):
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


# ------------------------------------------------------------------- tls ----
def _openssl(args, data):
    r = subprocess.run(["openssl", *args], input=data, capture_output=True)
    if r.returncode != 0:
        die(f"openssl {' '.join(args)} failed: "
            f"{r.stderr.decode(errors='replace').strip()}")
    return r.stdout


def cert_identity(pem):
    """(sha256 fingerprint, base64 SPKI) for a PEM certificate."""
    der = _openssl(["x509", "-pubkey", "-noout"], pem)
    der = _openssl(["pkey", "-pubin", "-outform", "der"], der)
    spki = base64.b64encode(hashlib.sha256(der).digest()).decode()
    fp = _openssl(["x509", "-noout", "-fingerprint", "-sha256"], pem)
    return fp.decode().strip().split("=", 1)[-1], spki


def read_cert(path):
    try:
        data = open(path, "rb").read()
    except OSError as e:
        die(f"cannot read {path}: {e}")
    if b"BEGIN CERTIFICATE" in data:
        return data
    return _openssl(["x509", "-inform", "der", "-outform", "pem"], data)


def fetch_peer_cert(host, port=443):
    cmd = ["openssl", "s_client", "-connect", f"{host}:{port}"]
    if not re.fullmatch(r"[0-9.]+", host):       # SNI with a bare IP breaks some stacks
        cmd += ["-servername", host]
    try:
        r = subprocess.run(cmd, input=b"", capture_output=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        die(f"could not run openssl s_client against {host}:{port}: {e}")
    m = re.search(rb"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
                  r.stdout, re.S)
    if not m:
        die(f"could not read the iDRAC certificate from {host}:{port}\n"
            f"{r.stderr.decode(errors='replace').strip()}")
    return m.group(0) + b"\n"


def read_pin_file(path):
    try:
        lines = open(path).read().splitlines()
    except OSError as e:
        die(f"cannot read --pin-file {path}: {e}")
    for ln in lines:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        m = re.search(r"(sha256//\S+)", ln)
        if m:
            return m.group(1)
    die(f"no sha256// pin in {path} - capture one with --trust-cert")


def write_pin_file(path, host, fingerprint, spki):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(f"# {host} {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        fh.write(f"# sha256 {fingerprint}\n")
        fh.write(f"sha256//{spki}\n")
    os.replace(tmp, path)
    os.chmod(path, 0o644)


def configure_tls(a):
    global TLS_ARGS
    pin = (a.pinned_pubkey or "").strip()
    if not pin and a.pin_cert:
        fp, spki = cert_identity(read_cert(a.pin_cert))
        print(f"pin from {a.pin_cert}: sha256 {fp}")
        pin = f"sha256//{spki}"
    if not pin and a.pin_file and not a.trust_cert:
        pin = read_pin_file(a.pin_file)
    if a.trust_cert:
        fp, spki = cert_identity(fetch_peer_cert(a.host))
        pin = f"sha256//{spki}"
        print(f"iDRAC certificate  : sha256 {fp}")
        print(f"pinned public key  : {pin}")
        if a.pin_file:
            write_pin_file(a.pin_file, a.host, fp, spki)
            print(f"pin stored in      : {a.pin_file}")
    pin = pin or os.environ.get("IDRAC_TLS_PIN", "").strip()
    if pin and "//" not in pin:
        pin = "sha256//" + pin
    cacert = a.cacert or os.environ.get("IDRAC_TLS_CACERT") or ""
    insecure = a.insecure or os.environ.get("IDRAC_TLS_INSECURE", "").lower() in (
        "1", "yes", "true", "on")

    if cacert and not os.access(cacert, os.R_OK):
        die(f"--cacert {cacert} is not readable")

    if insecure:
        if not pin:
            print("warning: TLS verification disabled (--insecure)", file=sys.stderr)
        TLS_ARGS = ["-k"] + (["--pinnedpubkey", pin] if pin else [])
        return

    args = []
    if cacert:
        args += ["--cacert", cacert]
    if pin:
        args += ["--pinnedpubkey", pin]
        if not cacert:
            # The pin replaces chain validation for expired factory certs.
            args.append("-k")
    TLS_ARGS = args


# --------------------------------------------------------------- transport --
def cfg_escape(s):
    return (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\r", "\\r"))


def curl(host, user, password, url, data=None, headers=None, timeout=120):
    """POST/GET through curl with the secret passed on stdin, not argv."""
    cmd = ["curl", "-sS", "--max-time", str(timeout), "--proto", "=https",
           "-K", "-", *TLS_ARGS]
    if data is not None:
        cmd += ["-X", "POST", "-H",
                "Content-Type: application/soap+xml;charset=UTF-8", "-d", data]
    for h in headers or []:
        cmd += ["-H", h]
    cmd.append(url)
    conf = f'user = "{cfg_escape(user + ":" + password)}"\n'
    r = subprocess.run(cmd, input=conf, capture_output=True, text=True)
    if r.returncode != 0:
        # curl's first line carries the reason; the rest is boilerplate.
        detail = [l for l in r.stderr.strip().splitlines() if l.strip()]
        raise CurlError(r.returncode,
                        f"{url}: {detail[0] if detail else 'curl failed'}")
    return r.stdout


def envelope(host, action, res, selectors="", body="", op_timeout=None):
    guard = (f'<wsman:OperationTimeout>PT{op_timeout}S</wsman:OperationTimeout>'
             if op_timeout else "")
    return (
        '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"'
        ' xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"'
        ' xmlns:wsman="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd">'
        f'<s:Header><wsa:To>https://{host}{WSMAN}</wsa:To>'
        '<wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/'
        'addressing/role/anonymous</wsa:Address></wsa:ReplyTo>'
        f'<wsa:MessageID>uuid:{uuid.uuid4()}</wsa:MessageID>'
        f'<wsa:Action>{action}</wsa:Action>'
        f'<wsman:ResourceURI>{res}</wsman:ResourceURI>'
        f'{selectors}{guard}</s:Header><s:Body>{body}</s:Body></s:Envelope>')


def wsman_post(host, user, password, action, res, selectors="", body="",
               timeout=120):
    out = curl(host, user, password, f"https://{host}{WSMAN}",
               data=envelope(host, action, res, selectors, body, op_timeout=timeout),
               timeout=timeout)
    m = re.search(r"<s:Body>(.*)</s:Body>", out, re.S)
    return m.group(1) if m else out


def wsman_invoke(host, user, password, cls, method, body_extra="", timeout=120):
    """Invoke a WSMAN method with Dell's standard singleton selector set."""
    res = f"{CIM}/{cls}"
    name = cls.replace("DCIM_", "")
    sel = (f'<wsman:SelectorSet>'
           f'<wsman:Selector Name="SystemCreationClassName">DCIM_ComputerSystem</wsman:Selector>'
           f'<wsman:Selector Name="SystemName">DCIM:ComputerSystem</wsman:Selector>'
           f'<wsman:Selector Name="CreationClassName">{cls}</wsman:Selector>'
           f'<wsman:Selector Name="Name">DCIM:{name}</wsman:Selector>'
           f'</wsman:SelectorSet>')
    body = f'<p:{method}_INPUT xmlns:p="{res}">{body_extra}</p:{method}_INPUT>'
    return wsman_post(host, user, password, f"{res}/{method}", res, sel, body,
                      timeout=timeout)


def parse_output(txt):
    rv = re.search(r"ReturnValue>(\d+)", txt)
    msg = re.search(r"Message>([^<]+)", txt)
    mid = re.search(r"MessageID>([^<]+)", txt)
    return (int(rv.group(1)) if rv else None,
            msg.group(1) if msg else "",
            mid.group(1) if mid else "")


def redfish_get(host, user, password, path, timeout=20):
    out = curl(host, user, password, f"https://{host}{path}", timeout=timeout)
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def redfish_sku(host, user, password):
    d = redfish_get(host, user, password, "/redfish/v1/Systems/System.Embedded.1")
    return d.get("SKU") if d else None


def license_tag(xml_text):
    m = re.search(r"<lns:ServiceTag>([^<]+)</lns:ServiceTag>", xml_text)
    return m.group(1) if m else None


# ------------------------------------------------------------------- jobs --
def parse_job(txt):
    """(resource URI, instance ID) of the job an LCC method queued."""
    block = re.search(r"<(?:\w+:)?Job>(.*?)</(?:\w+:)?Job>", txt, re.S)
    blk = block.group(1) if block else txt
    uri = re.search(r"<(?:\w+:)?ResourceURI>([^<]+)</", blk)
    jid = (re.search(r'Selector Name="InstanceID">([^<]+)<', blk)
           or re.search(r"\b(JID_[A-Za-z0-9_]+)\b", blk))
    if not jid:
        return None
    return (uri.group(1) if uri else JOB_RES, jid.group(1))


def job_state(host, user, password, res_uri, jid, timeout=60):
    """Read one lifecycle job instance (WS-Transfer Get by InstanceID)."""
    sel = (f'<wsman:SelectorSet>'
           f'<wsman:Selector Name="InstanceID">{jid}</wsman:Selector>'
           f'<wsman:Selector Name="__cimnamespace">root/dcim</wsman:Selector>'
           f'</wsman:SelectorSet>')
    txt = wsman_post(host, user, password, ACT_GET, res_uri, sel, timeout=timeout)

    def field(tag):
        m = re.search(rf"<(?:\w+:)?{tag}>([^<]*)<", txt)
        return m.group(1) if m else ""

    return {"instance_id": jid, "status": field("JobStatus"),
            "percent": field("PercentComplete"), "name": field("Name"),
            "message": field("Message"), "message_id": field("MessageID")}


def wait_job(host, user, password, job, timeout, interval=10):
    """Poll to a terminal state. 0 done, 3 failed, 2 still running."""
    uri, jid = job
    deadline = time.time() + timeout
    last = None
    while True:
        st = job_state(host, user, password, uri, jid)
        line = (f"{jid}: {st['status'] or '?'} {st['percent'] or '0'}%"
                f"{' - ' + st['message'] if st['message'] and st['message'] != 'NA' else ''}")
        if line != last:
            print(f"  {line}")
            last = line
        if st["status"] in JOB_OK:
            return 0, st
        if st["status"] in JOB_BAD:
            return 3, st
        if time.time() >= deadline:
            return 2, st
        time.sleep(interval)


def stat_sig(paths):
    sig = {}
    for p in paths:
        try:
            st = os.stat(p)
            sig[p] = (st.st_size, st.st_mtime_ns)
        except OSError:
            sig[p] = None
    return sig


def verify_export(paths, before, grace=30):
    """0 verified, 3 stale/missing, 2 not checkable from here."""
    if not paths:
        return 2, "the share is not mounted on this host"
    deadline = time.time() + grace
    detail = ""
    while True:
        for p in paths:
            try:
                st = os.stat(p)
            except OSError:
                detail = f"no file at {p}"
                continue
            if st.st_size < 512:
                detail = f"{p} is only {st.st_size} bytes"
                continue
            if before.get(p) == (st.st_size, st.st_mtime_ns):
                detail = f"{p} was not rewritten by this export"
                continue
            with open(p, "rb") as fh:
                head = fh.read(64).lstrip()
            if not head.startswith(b"<"):
                detail = f"{p} is not XML"
                continue
            return 0, f"{p} ({st.st_size} bytes, {time.ctime(st.st_mtime)})"
        if time.time() >= deadline:
            return 3, detail
        time.sleep(3)


# ---------------------------------------------------------------- commands --
def cmd_check(a):
    sku = redfish_sku(a.host, a.user, a.password)
    if sku is None:
        print("iDRAC not answering on Redfish", file=sys.stderr)
        return 2
    print(f"iDRAC service tag : {sku}")
    if a.license:
        xml_text = open(a.license).read()
        print(f"license binds to  : {license_tag(xml_text)}")
        a.tag = license_tag(xml_text)
    if a.tag:
        print(f"expected tag      : {a.tag}")
        return 0 if sku == a.tag else 2
    return 0


def cmd_import(a):
    xml_text = open(a.license).read()
    ltag = license_tag(xml_text)
    target = a.tag or ltag
    if ltag != target:
        print(f"license tag '{ltag}' != expected '{target}'", file=sys.stderr)
        return 4
    sku = redfish_sku(a.host, a.user, a.password)
    if sku is None:
        print("iDRAC not answering on Redfish", file=sys.stderr)
        return 2
    print(f"iDRAC service tag : {sku}")
    if sku != target:
        print(f"tag not latched yet ({sku}) - host has not POSTed with {target}",
              file=sys.stderr)
        return 2
    b64 = base64.b64encode(xml_text.encode()).decode()
    txt = wsman_invoke(a.host, a.user, a.password, "DCIM_LicenseManagementService",
                       "ImportLicense",
                       f"<p:LicenseFile>{b64}</p:LicenseFile>"
                       f"<p:FQDD>iDRAC.Embedded.1</p:FQDD><p:ImportOptions>1</p:ImportOptions>")
    rv, msg, mid = parse_output(txt)
    print(f"ImportLicense     : ReturnValue={rv} [{mid}] {msg}")
    if rv == 0 or mid in ("LIC900", "LIC018"):  # LIC018 = already imported
        return 0
    if mid == "LIC008" or "binding ID" in msg:
        return 2
    return 3


def cmd_export_license(a):
    if not a.entitlement_id:
        print("--entitlement-id required (from <lns:EntitlementID> in the XML)",
              file=sys.stderr)
        return 4
    txt = wsman_invoke(a.host, a.user, a.password, "DCIM_LicenseManagementService",
                       "ExportLicense",
                       f"<p:EntitlementID>{a.entitlement_id}</p:EntitlementID>"
                       f"<p:FQDD>iDRAC.Embedded.1</p:FQDD>")
    m = re.search(r"<n1:LicenseFile>([^<]+)</n1:LicenseFile>", txt)
    rv, msg, mid = parse_output(txt)
    if not m:
        print(f"ExportLicense: ReturnValue={rv} [{mid}] {msg}", file=sys.stderr)
        return 3
    raw = base64.b64decode(m.group(1))
    out = a.out or f"license-{a.host}.xml"
    open(out, "wb").write(raw)
    print(f"ExportLicense     : {len(raw)} bytes -> {out}")
    return 0


def _lcc_share_args(a):
    """Share parameters accepted by both LCC export methods."""
    st = {"nfs": "0", "cifs": "2"}.get(a.share_type, a.share_type)
    return (f"<p:ShareType>{st}</p:ShareType>"
            f"<p:IPAddress>{a.share_ip}</p:IPAddress>"
            f"<p:ShareName>{a.share_path}</p:ShareName>"
            f"<p:FileName>{a.file_name}</p:FileName>")


def export_candidates(a):
    """Local paths the iDRAC should write, or [] when the share is elsewhere."""
    if a.verify_path:
        return [a.verify_path]
    if not os.path.isdir(a.share_path):
        return []
    base = os.path.join(a.share_path, a.file_name)
    return [base] if base.endswith(".xml") else [base, base + ".xml"]


def run_export(a, method, cls):
    """Queue an LCC export, follow its job, then confirm the file landed."""
    paths = export_candidates(a)
    before = stat_sig(paths)

    txt = wsman_invoke(a.host, a.user, a.password, cls, method,
                       _lcc_share_args(a), timeout=300)
    rv, msg, mid = parse_output(txt)
    print(f"{method}: ReturnValue={rv} [{mid}] {msg}".rstrip())
    job = parse_job(txt)
    if rv not in (0, 4096):
        return 3
    if not job:
        print("no job id in the response - cannot confirm the export",
              file=sys.stderr)
        return 2
    if a.no_wait:
        print(f"job {job[1]} queued (--no-wait): export NOT verified")
        return 0
    print(f"job {job[1]} queued - waiting up to {a.wait}s")

    rc, st = wait_job(a.host, a.user, a.password, job, a.wait, a.wait_interval)
    if rc == 3:
        print(f"job failed: {st['message'] or st['status']} [{st['message_id']}]",
              file=sys.stderr)
        return 3
    if rc == 2:
        print(f"job still {st['status'] or 'running'} after {a.wait}s - "
              f"check it with: job-status --job {job[1]}", file=sys.stderr)
        return 2

    if not paths:
        print(f"job completed, but {a.share_path} is not mounted on this host: "
              f"cannot verify the file (use --verify-path)", file=sys.stderr)
        return 2
    rc, detail = verify_export(paths, before, a.verify_grace)
    if rc == 0:
        print(f"verified          : {detail}")
        return 0
    print(f"job completed but no usable export: {detail}", file=sys.stderr)
    return 3


def cmd_export_config(a):
    return run_export(a, "ExportSystemConfiguration", "DCIM_LCService")


def cmd_export_factory(a):
    # FileName must be a bare name (no extension) for the factory export.
    return run_export(a, "ExportFactoryConfiguration", "DCIM_LCService")


def cmd_job_status(a):
    if not a.job:
        print("--job JID_... required for job-status", file=sys.stderr)
        return 4
    st = job_state(a.host, a.user, a.password, JOB_RES, a.job)
    if not st["status"]:
        print(f"{a.job}: no such job (the iDRAC returned no instance)",
              file=sys.stderr)
        return 2
    print(f"{st['instance_id']}: {st['status']} {st['percent'] or '0'}%"
          f" - {st['name'] or '?'}")
    if st["message"] and st["message"] != "NA":
        print(f"  {st['message']} [{st['message_id']}]")
    if st["status"] in JOB_OK:
        return 0
    return 3 if st["status"] in JOB_BAD else 2


# ---------------------------------------------------------------- password --
def resolve_password(a):
    if a.password_file:
        try:
            pw = open(a.password_file).readline().rstrip("\r\n")
        except OSError as e:
            die(f"cannot read --password-file: {e}")
        if os.stat(a.password_file).st_mode & 0o077:
            print(f"warning: {a.password_file} is readable by group/other - "
                  f"chmod 600 it", file=sys.stderr)
        return pw
    if a.password:
        print("warning: --password is visible in the process list - prefer "
              "--password-file or IDRAC_PASS", file=sys.stderr)
        return a.password
    if os.environ.get("IDRAC_PASS"):
        return os.environ["IDRAC_PASS"]
    if sys.stdin.isatty():
        return getpass.getpass(f"iDRAC password for {a.user}@{a.host}: ")
    die("no password: use --password-file, IDRAC_PASS, or run on a terminal")


# ------------------------------------------------------------------- main --
def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "import", "export-license",
                                    "export-config", "export-factory",
                                    "job-status"])
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", help="visible in ps - prefer --password-file")
    ap.add_argument("--password-file", help="file whose first line is the password")
    ap.add_argument("--tag", help="expected service tag")
    ap.add_argument("--license", help="path to the license XML")
    ap.add_argument("--entitlement-id", help="<lns:EntitlementID> for export-license")
    ap.add_argument("--out", help="output file for export-license")
    ap.add_argument("--job", help="JID_... for job-status")
    ap.add_argument("--share-ip", help="NFS/CIFS server IP for config exports")
    ap.add_argument("--share-path", help="export path on the share, e.g. /srv/idrac-export")
    ap.add_argument("--share-type", choices=["nfs", "cifs"], default="nfs")
    ap.add_argument("--file-name", help="file name on the share (bare name for factory)")
    ap.add_argument("--cacert", help="CA/self-signed cert for full verification")
    ap.add_argument("--pinned-pubkey", help="curl sha256//... public key pin")
    ap.add_argument("--pin-cert", help="derive the pin from this certificate")
    ap.add_argument("--pin-file", help="read (or with --trust-cert, store) the pin")
    ap.add_argument("--trust-cert", action="store_true",
                    help="pin the certificate the iDRAC presents right now")
    ap.add_argument("--insecure", action="store_true",
                    help="disable TLS verification (loudly)")
    ap.add_argument("--wait", type=int, default=900,
                    help="seconds to follow an export job (default 900)")
    ap.add_argument("--no-wait", action="store_true",
                    help="return as soon as the job is queued (unverified)")
    ap.add_argument("--wait-interval", type=int, default=10)
    ap.add_argument("--verify-path", help="local path of the exported file")
    ap.add_argument("--verify-grace", type=int, default=30,
                    help="seconds to wait for the file to appear (default 30)")
    a = ap.parse_args()

    if a.cmd in ("export-config", "export-factory"):
        for k in ("share_ip", "share_path", "file_name"):
            if not getattr(a, k):
                print(f"--{k.replace('_', '-')} required for {a.cmd}",
                      file=sys.stderr)
                return 4

    a.password = resolve_password(a)
    try:
        configure_tls(a)
        return {
            "check": cmd_check, "import": cmd_import,
            "export-license": cmd_export_license,
            "export-config": cmd_export_config,
            "export-factory": cmd_export_factory,
            "job-status": cmd_job_status,
        }[a.cmd](a)
    except CurlError as e:
        print(f"error: {e}", file=sys.stderr)
        if e.rc in CURL_HINTS:
            print(f"hint: {CURL_HINTS[e.rc]}", file=sys.stderr)
        return 3 if e.rc in (60, 90) else 2


if __name__ == "__main__":
    sys.exit(main())
