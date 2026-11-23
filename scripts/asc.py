#!/usr/bin/env python3
"""App Store Connect release steps for the release workflow.

usage:
  asc.py next-build                                   print the next 2026MMDDNN build number
  asc.py prepare-version <version>                    editable tvOS + iOS store versions named <version>
  asc.py wait-valid <build>                           wait until both platforms' builds are VALID
  asc.py attach <version> <build>                     attach the build to both store versions
  asc.py submit <version>                             submit both store versions for review

env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (.p8), ASC_APP_ID
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.request

import jwt

PLATFORMS = ("TV_OS", "IOS")
EDITABLE = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY"}
APP = os.environ.get("ASC_APP_ID", "")


def token():
    now = int(time.time())
    key = open(os.path.expanduser(os.environ["ASC_KEY_PATH"])).read()
    return jwt.encode({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": os.environ["ASC_KEY_ID"]})


def call(method, path, body=None):
    url = path if path.startswith("https://") else "https://api.appstoreconnect.apple.com/v1/" + path
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path.split('?')[0]}: HTTP {e.code} {e.read().decode(errors='replace')[:2000]}")


def get_all(path):
    out, nxt = [], path
    while nxt:
        d = call("GET", nxt)
        out += d["data"]
        nxt = d.get("links", {}).get("next")
    return out


def next_build(today=None):
    prefix = (today or datetime.datetime.now(datetime.timezone.utc).date()).strftime("%Y%m%d")
    versions = [b["attributes"]["version"] for b in
                get_all(f"builds?filter[app]={APP}&fields[builds]=version&sort=-uploadedDate&limit=200")]
    return next_build_from(prefix, versions)


def next_build_from(prefix, versions):
    taken = [int(v[8:]) for v in versions if v.startswith(prefix) and len(v) == 10 and v[8:].isdigit()]
    n = max(taken, default=0) + 1
    if n > 99:
        sys.exit(f"no build numbers left for {prefix}")
    return f"{prefix}{n:02d}"


def store_versions():
    vs = get_all(f"apps/{APP}/appStoreVersions?fields[appStoreVersions]=platform,versionString,appStoreState&limit=200")
    return {p: [v for v in vs if v["attributes"]["platform"] == p] for p in PLATFORMS}


def prepare_version(version):
    ids = {}
    for platform, vs in store_versions().items():
        named = [v for v in vs if v["attributes"]["versionString"] == version]
        editable = [v for v in vs if v["attributes"]["appStoreState"] in EDITABLE]
        if named:
            v = named[0]
            if v["attributes"]["appStoreState"] not in EDITABLE:
                sys.exit(f"{platform} {version} is {v['attributes']['appStoreState']}, not editable")
        elif editable:
            v = editable[0]
            call("PATCH", f"appStoreVersions/{v['id']}",
                 {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": {"versionString": version}}})
        else:
            v = call("POST", "appStoreVersions", {"data": {
                "type": "appStoreVersions",
                "attributes": {"platform": platform, "versionString": version, "releaseType": "AFTER_APPROVAL"},
                "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
        call("PATCH", f"appStoreVersions/{v['id']}",
             {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": {"releaseType": "AFTER_APPROVAL"}}})
        ids[platform] = v["id"]
        print(f"{platform} {version}: {v['id']}")
    return ids


def builds(build):
    d = call("GET", f"builds?filter[app]={APP}&filter[version]={build}&include=preReleaseVersion"
                    "&fields[builds]=version,processingState,preReleaseVersion&fields[preReleaseVersions]=platform")
    platform = {p["id"]: p["attributes"]["platform"] for p in d.get("included", [])}
    return {platform.get(b["relationships"]["preReleaseVersion"]["data"]["id"]): b for b in d["data"]}


def wait_valid(build, timeout=3600):
    deadline = time.time() + timeout
    while True:
        found = builds(build)
        states = {p: found[p]["attributes"]["processingState"] if p in found else "MISSING" for p in PLATFORMS}
        print(f"{build}: {states}", flush=True)
        if any(s in ("FAILED", "INVALID") for s in states.values()):
            sys.exit(f"build {build} rejected by processing: {states}")
        if all(s == "VALID" for s in states.values()):
            return found
        if time.time() > deadline:
            sys.exit(f"build {build} not VALID after {timeout}s")
        time.sleep(30)


def attach(version, build):
    ids = prepare_version(version)
    found = builds(build)
    for platform in PLATFORMS:
        b = found[platform]
        call("PATCH", f"appStoreVersions/{ids[platform]}/relationships/build", {"data": {"type": "builds", "id": b["id"]}})
        print(f"{platform} {version} <- build {build} ({b['id']})")


def submit(version):
    for platform, vs in store_versions().items():
        v = next(v for v in vs if v["attributes"]["versionString"] == version)
        s = call("POST", "reviewSubmissions", {"data": {
            "type": "reviewSubmissions", "attributes": {"platform": platform},
            "relationships": {"app": {"data": {"type": "apps", "id": APP}}}}})["data"]
        call("POST", "reviewSubmissionItems", {"data": {
            "type": "reviewSubmissionItems",
            "relationships": {"reviewSubmission": {"data": {"type": "reviewSubmissions", "id": s["id"]}},
                              "appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}})
        call("PATCH", f"reviewSubmissions/{s['id']}",
             {"data": {"type": "reviewSubmissions", "id": s["id"], "attributes": {"submitted": True}}})
        print(f"{platform} {version}: submitted for review ({s['id']})")


def main(argv):
    cmd, args = (argv[1], argv[2:]) if len(argv) > 1 else ("", [])
    if cmd == "next-build" and not args:
        print(next_build())
    elif cmd == "prepare-version" and len(args) == 1:
        prepare_version(*args)
    elif cmd == "wait-valid" and len(args) == 1:
        wait_valid(*args)
    elif cmd == "attach" and len(args) == 2:
        attach(*args)
    elif cmd == "submit" and len(args) == 1:
        submit(*args)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
