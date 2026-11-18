#!/usr/bin/env python3
"""Import a Dell license XML into iDRAC7 via WSMAN.

Redfish on iDRAC7 firmware 2.65 exposes no license endpoint, but the
WSMAN DCIM_LicenseManagementService.ImportLicense method works even on
Express. This script:

  1. reads the iDRAC's current service tag (Redfish SKU field),
  2. refuses to proceed until the tag matches the license's tag,
  3. invokes ImportLicense (LicenseFile = base64 of the XML),
  4. maps the result to exit codes the caller can retry on.

Exit codes:
  0  license imported (or already installed)
  2  tag not latched / license rejected for binding (retry after POST)
  3  call failed for another reason
  4  usage error

Params discovered live against iDRAC7 2.65:
  LicenseFile  (base64 of the license XML)
  FQDD         iDRAC.Embedded.1
  ImportOptions 1
Errors: LIC903 missing param, LIC017 bad file encoding, LIC008 binding
mismatch, LIC901 bad ImportOptions value.
"""
import argparse
import base64
import json
import re
import sys
import uuid
from xml.sax.saxutils import escape

RES = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/root/dcim/DCIM_LicenseManagementService"
LIC008 = "LIC008"  # binding ID mismatch = tag not latched yet (retry)
LIC900 = "LIC900"  # success


def redfish_sku(host, user, password, timeout=15):
    import subprocess
    url = f"https://{host}/redfish/v1/Systems/System.Embedded.1"
    r = subprocess.run(
        ["curl", "-sk", "--max-time", str(timeout), "-u", f"{user}:{password}", url],
        capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        d = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    return d.get("SKU")


def license_tag(xml_text):
    m = re.search(r"<lns:ServiceTag>([^<]+)</lns:ServiceTag>", xml_text)
    return m.group(1) if m else None


def wsman_import(host, user, password, license_b64, timeout=120):
    import subprocess
    body = f"""<p:ImportLicense_INPUT xmlns:p="{RES}">
  <p:LicenseFile>{license_b64}</p:LicenseFile>
  <p:FQDD>iDRAC.Embedded.1</p:FQDD>
  <p:ImportOptions>1</p:ImportOptions>
</p:ImportLicense_INPUT>"""
    env = f"""<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:wsman="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd"><s:Header><wsa:To>https://{host}/wsman</wsa:To><wsa:ReplyTo><wsa:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:Address></wsa:ReplyTo><wsa:MessageID>uuid:{uuid.uuid4()}</wsa:MessageID><wsa:Action>{RES}/ImportLicense</wsa:Action><wsman:ResourceURI>{RES}</wsman:ResourceURI><wsman:SelectorSet><wsman:Selector Name="SystemCreationClassName">DCIM_ComputerSystem</wsman:Selector><wsman:Selector Name="SystemName">DCIM:ComputerSystem</wsman:Selector><wsman:Selector Name="CreationClassName">DCIM_LicenseManagementService</wsman:Selector><wsman:Selector Name="Name">DCIM:LicenseManagementService</wsman:Selector></wsman:SelectorSet><wsman:OperationTimeout>PT{timeout}S</wsman:OperationTimeout></s:Header><s:Body>{body}</s:Body></s:Envelope>"""
    r = subprocess.run(
        ["curl", "-sk", "--max-time", str(timeout + 10), "-u", f"{user}:{password}",
         "-X", "POST", "-H", "Content-Type: application/soap+xml;charset=UTF-8",
         "-d", env, f"https://{host}/wsman"],
        capture_output=True, text=True)
    if r.returncode != 0:
        return None, None, f"curl failed rc={r.returncode}"
    rv = re.search(r"<n1:ReturnValue>(\d+)</n1:ReturnValue>", r.stdout)
    msg = re.search(r"<n1:Message>([^<]*)</n1:Message>", r.stdout)
    mid = re.search(r"<n1:MessageID>([^<]*)</n1:MessageID>", r.stdout)
    if not rv:
        return None, None, f"no ReturnValue in response ({len(r.stdout)} bytes)"
    return int(rv.group(1)), \
           (msg.group(1) if msg else ""), \
           (mid.group(1) if mid else "")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--license", required=True, help="path to the license XML")
    ap.add_argument("--tag", required=True, help="service tag the license binds to")
    ap.add_argument("--check-only", action="store_true",
                    help="only report the iDRAC's tag, do not import")
    args = ap.parse_args()

    xml_text = open(args.license).read()
    ltag = license_tag(xml_text)
    if ltag != args.tag:
        print(f"license tag '{ltag}' != expected '{args.tag}'", file=sys.stderr)
        return 4

    sku = redfish_sku(args.host, args.user, args.password)
    if sku is None:
        print("iDRAC not answering on Redfish yet", file=sys.stderr)
        return 2
    print(f"iDRAC service tag : {sku}")
    print(f"license binds to  : {args.tag}")

    if args.check_only:
        return 0 if sku == args.tag else 2

    if sku != args.tag:
        print(f"tag not latched yet ({sku}) - host has not POSTed with the new tag",
              file=sys.stderr)
        return 2

    lic_b64 = base64.b64encode(xml_text.encode()).decode()
    rv, msg, mid = wsman_import(args.host, args.user, args.password, lic_b64)
    print(f"ImportLicense     : ReturnValue={rv} [{mid}] {msg}")
    if rv == 0 or mid == LIC900:
        return 0
    if mid == LIC008 or (msg and "binding ID" in msg):
        print("binding mismatch - tag changed after the latch check? retry", file=sys.stderr)
        return 2
    return 3


if __name__ == "__main__":
    sys.exit(main())
