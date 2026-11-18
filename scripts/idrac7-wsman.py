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

Exit codes: 0 ok, 2 retryable (tag not latched / job queued), 3 failed.

Background (why this exists): an iDRAC7 license is RSA-signed for one
service tag; svctag rewrites the tag the host reports. After a POST the
iDRAC re-latches it and `import` succeeds with LIC900.
"""
import argparse
import base64
import json
import re
import subprocess
import sys
import uuid
from xml.sax.saxutils import escape

WSMAN = "/wsman"
CIM = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim"
LIC_SVC = f"{CIM}/DCIM_LicenseManagementService"
LC_SVC = f"{CIM}/DCIM_LCService"

SEL = {
    "SystemCreationClassName": "DCIM_ComputerSystem",
    "SystemName": "DCIM:ComputerSystem",
    "CreationClassName": None,   # filled per class
    "Name": None,
}


def curl(host, user, password, url, data=None, headers=None, timeout=120):
    cmd = ["curl", "-sk", "-u", f"{user}:{password}", "--max-time", str(timeout)]
    if data is not None:
        cmd += ["-X", "POST", "-H", "Content-Type: application/soap+xml;charset=UTF-8", "-d", data]
    for h in headers or []:
        cmd += ["-H", h]
    cmd.append(url)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout


def wsman_invoke(host, user, password, cls, method, body_extra="", timeout=120):
    """Invoke a WSMAN method with Dell's standard singleton selector set."""
    res = f"{CIM}/{cls}"
    name = cls.replace("DCIM_", "")
    sel = f"""<wsman:SelectorSet><wsman:Selector Name="SystemCreationClassName">DCIM_ComputerSystem</wsman:Selector><wsman:Selector Name="SystemName">DCIM:ComputerSystem</wsman:Selector><wsman:Selector Name="CreationClassName">{cls}</wsman:Selector><wsman:Selector Name="Name">DCIM:{name}</wsman:Selector></wsman:SelectorSet>"""
    body = f'<p:{method}_INPUT xmlns:p="{res}">{body_extra}</p:{method}_INPUT>'
    env = f"""<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsman="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"><s:Header><wsa:To>https://{host}{WSMAN}</wsa:To><wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo><wsa:MessageID>uuid:{uuid.uuid4()}</wsa:MessageID><wsa:Action>{res}/{method}</wsa:Action><wsman:ResourceURI>{res}</wsman:ResourceURI>{sel}<wsman:OperationTimeout>PT{timeout}S</wsman:OperationTimeout></s:Header><s:Body>{body}</s:Body></s:Envelope>"""
    out = curl(host, user, password, f"https://{host}{WSMAN}", data=env, timeout=timeout)
    m = re.search(r"<s:Body>(.*)</s:Body>", out, re.S)
    return m.group(1) if m else out


def parse_output(txt):
    rv = re.search(r"ReturnValue>(\d+)", txt)
    msg = re.search(r"Message>([^<]+)", txt)
    mid = re.search(r"MessageID>([^<]+)", txt)
    job = re.search(r"<n1:Job>", txt)
    return (int(rv.group(1)) if rv else None,
            msg.group(1) if msg else "",
            mid.group(1) if mid else "",
            bool(job))


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
    rv, msg, mid, _ = parse_output(txt)
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
    rv, msg, mid, _ = parse_output(txt)
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


def cmd_export_config(a):
    txt = wsman_invoke(a.host, a.user, a.password, "DCIM_LCService",
                       "ExportSystemConfiguration", _lcc_share_args(a),
                       timeout=300)
    rv, msg, mid, job = parse_output(txt)
    print(f"ExportSystemConfiguration: ReturnValue={rv} [{mid}] {msg}")
    print("job queued - the XML lands on the share within ~2 min" if job else "")
    return 0 if rv in (0, 4096) else 3


def cmd_export_factory(a):
    # FileName must be a bare name (no extension) for the factory export.
    txt = wsman_invoke(a.host, a.user, a.password, "DCIM_LCService",
                       "ExportFactoryConfiguration", _lcc_share_args(a),
                       timeout=300)
    rv, msg, mid, job = parse_output(txt)
    print(f"ExportFactoryConfiguration: ReturnValue={rv} [{mid}] {msg}")
    print("job queued - CIM-format factory baseline lands on the share" if job else "")
    return 0 if rv in (0, 4096) else 3


# ------------------------------------------------------------------- main --
def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "import", "export-license",
                                    "export-config", "export-factory"])
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--tag", help="expected service tag")
    ap.add_argument("--license", help="path to the license XML")
    ap.add_argument("--entitlement-id", help="<lns:EntitlementID> for export-license")
    ap.add_argument("--out", help="output file for export-license")
    ap.add_argument("--share-ip", help="NFS/CIFS server IP for config exports")
    ap.add_argument("--share-path", help="export path on the share, e.g. /srv/idrac-export")
    ap.add_argument("--share-type", choices=["nfs", "cifs"], default="nfs")
    ap.add_argument("--file-name", help="file name on the share (bare name for factory)")
    a = ap.parse_args()

    if a.cmd in ("export-config", "export-factory"):
        for k in ("share_ip", "share_path", "file_name"):
            if not getattr(a, k):
                print(f"--{k.replace('_','-')} required for {a.cmd}", file=sys.stderr)
                return 4

    return {
        "check": cmd_check, "import": cmd_import,
        "export-license": cmd_export_license,
        "export-config": cmd_export_config, "export-factory": cmd_export_factory,
    }[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
