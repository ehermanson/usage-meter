#!/usr/bin/env python3
"""Fail before signing if a CloudKit profile doesn't authorize this Mac app."""
import datetime
import plistlib
import subprocess
import sys

result = subprocess.run(["security", "cms", "-D", "-i", sys.argv[1]], capture_output=True)
if result.returncode:
    sys.exit("Could not decode the companion provisioning profile.")
profile = plistlib.loads(result.stdout)
entitlements = profile.get("Entitlements", {})
identifier = entitlements.get("com.apple.application-identifier", entitlements.get("application-identifier", ""))
checks = [
    identifier == "2YN57RAL6Q.com.erichermanson.usagemeter",
    "iCloud.com.erichermanson.usagemeter" in entitlements.get("com.apple.developer.icloud-container-identifiers", []),
    entitlements.get("com.apple.developer.icloud-services") == "*"
    or "CloudKit" in entitlements.get("com.apple.developer.icloud-services", []),
    "Production" in entitlements.get("com.apple.developer.icloud-container-environment", []),
    profile.get("ExpirationDate", datetime.datetime.min) > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
]
if not all(checks):
    sys.exit("Profile must authorize Usage Meter, its CloudKit container, Production, and be unexpired.")
print("Companion provisioning profile validated.")
