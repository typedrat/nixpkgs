#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3

from dataclasses import asdict, dataclass, field
from enum import StrEnum
from typing import List
import base64
import json
import urllib.request
import os.path
import tempfile
import zipfile

# pmovmskb %xmm0, %eax + cmp $0xffff, %eax
KRISP_PATCH_SIGNATURE = b"\x66\x0f\xd7\xc0\x3d\xff\xff\x00\x00"
# Apple Security framework API used as the anchor for Mach-O call-chain tracing
ANCHOR_IMPORT = b"_SecStaticCodeCreateWithPath"

class Platform(StrEnum):
    LINUX = "linux"
    MACOS = "osx"


class Branch(StrEnum):
    STABLE = "stable"
    PTB = "ptb"
    CANARY = "canary"
    DEVELOPMENT = "development"


class Kind(StrEnum):
    # Brotli-compressed host + module distros from the distributions API
    DISTRO = "distro"


@dataclass(frozen=True)
class Variant:
    platform: Platform
    branch: Branch
    kind: Kind


# The distributions API rejects requests that don't send a Discord-Updater
# User-Agent, so we can't identify ourselves as Nixpkgs here
DISTRO_USER_AGENT = "Discord-Updater/1"


def serialize_variant(variant: Variant) -> str:
    return f"{variant.platform}-{variant.branch}"


def distro_manifest_url_for_variant(variant: Variant) -> str:
    return f"https://updates.discord.com/distributions/app/manifests/latest?channel={variant.branch.value}&platform={variant.platform.value}&arch=x64"


@dataclass
class DistroRef:
    url: str
    hash: str


@dataclass
class DistroModule:
    version: int
    url: str
    hash: str


@dataclass
class DistroSource:
    version: str
    distro: DistroRef
    modules: dict[str, DistroModule] = field(default_factory=dict)
    kind: Kind = Kind.DISTRO


def fetch_distro_manifest(variant: Variant) -> dict:
    url = distro_manifest_url_for_variant(variant)
    req = urllib.request.Request(url, headers={"User-Agent": DISTRO_USER_AGENT})
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read())


def version_triple_to_str(triple: list) -> str:
    return ".".join(str(x) for x in triple)


def sri_from_sha256_hex(hex_hash: str) -> str:
    return "sha256-" + base64.b64encode(bytes.fromhex(hex_hash)).decode("utf-8")


def fetch_distro_source(variant: Variant) -> DistroSource:
    manifest = fetch_distro_manifest(variant)

    distro_url = manifest["full"]["url"]
    modules = {
        name: DistroModule(
            version=mod["full"]["module_version"],
            url=mod["full"]["url"],
            hash=sri_from_sha256_hex(mod["full"]["package_sha256"]),
        )
        for name, mod in manifest["modules"].items()
    }

    return DistroSource(
        version=version_triple_to_str(manifest["full"]["host_version"]),
        distro=DistroRef(
            url=distro_url,
            hash=sri_from_sha256_hex(manifest["full"]["package_sha256"]),
        ),
        modules=modules,
    )


def prefetch(url: str) -> str:
    """Prefetch a URL and return the SRI hash."""
    with tempfile.TemporaryDirectory() as tmpdir:
        url_hash = os.popen(f"nix-prefetch-url --name source {url}").read().strip()
        return sri_from_sha256_hex(
            os.popen(f"nix-hash --to-base16 --type sha256 {url_hash}").read().strip()
        )


def fetch_krisp_module_url(branch, version, platform):
    """Return the krisp module download URL, or None if unavailable."""
    headers = {"user-agent": "Nixpkgs-Discord-Update-Script/0.0.0"}
    url = f"https://discord.com/api/modules/{branch.value}/versions.json?host_version={version}&platform={platform.value}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req) as response:
        modules = json.loads(response.read())

    if "discord_krisp" not in modules:
        return None

    krisp_ver = modules["discord_krisp"]
    download_url = f"https://discord.com/api/modules/{branch.value}/discord_krisp/{krisp_ver}?host_version={version}&platform={platform.value}"
    return download_url


def verify_krisp_patchable(url):
    """Download krisp and check it contains the expected patchable target."""
    headers = {"user-agent": "Nixpkgs-Discord-Update-Script/0.0.0"}
    with tempfile.TemporaryDirectory() as tmpdir:
        zip_path = os.path.join(tmpdir, "krisp.zip")
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req) as resp, open(zip_path, "wb") as f:
            f.write(resp.read())

        with zipfile.ZipFile(zip_path) as zf:
            if "discord_krisp.node" not in zf.namelist():
                print("  WARNING: discord_krisp.node not found in zip")
                return False
            zf.extract("discord_krisp.node", tmpdir)

        with open(os.path.join(tmpdir, "discord_krisp.node"), "rb") as f:
            data = f.read()

        # ELF: check for MD5 comparison byte pattern (exactly 1 match)
        if data[:4] == b"\x7fELF":
            count = data.count(KRISP_PATCH_SIGNATURE)
            if count != 1:
                print(f"  WARNING: found {count} ELF signature matches (expected 1)")
                return False
            print("  Verified: ELF signature pattern found (1 unique match)")
            return True

        if ANCHOR_IMPORT in data:
            print("  Verified: Mach-O contains _SecStaticCodeCreateWithPath import")
            return True

        print("  WARNING: no patchable target found")
        return False


def main():
    variants: List[Variant] = [
        Variant(Platform.LINUX, Branch.STABLE, Kind.DISTRO),
        Variant(Platform.LINUX, Branch.PTB, Kind.DISTRO),
        Variant(Platform.LINUX, Branch.CANARY, Kind.DISTRO),
        Variant(Platform.LINUX, Branch.DEVELOPMENT, Kind.DISTRO),
        Variant(Platform.MACOS, Branch.STABLE, Kind.DISTRO),
        Variant(Platform.MACOS, Branch.PTB, Kind.DISTRO),
        Variant(Platform.MACOS, Branch.CANARY, Kind.DISTRO),
        Variant(Platform.MACOS, Branch.DEVELOPMENT, Kind.DISTRO),
    ]

    sources = {}

    for v in variants:
        sources[serialize_variant(v)] = asdict(fetch_distro_source(v))

    for v in variants:
        platform, branch = v.platform, v.branch
        version = sources[serialize_variant(v)]["version"]
        print(
            f"Fetching krisp module for {platform.value}/{branch.value} (v{version})..."
        )

        try:
            krisp_url = fetch_krisp_module_url(branch, version, platform)
            if krisp_url is None:
                print(
                    f"  No krisp module available for {platform.value}/{branch.value}"
                )
                continue

            if not verify_krisp_patchable(krisp_url):
                print(
                    f"  WARNING: Krisp for {platform.value}/{branch.value} is NOT patchable, skipping"
                )
                continue

            krisp_hash = prefetch(krisp_url)
            sources[f"{serialize_variant(v)}-krisp"] = {
                "url": krisp_url,
                "version": krisp_url
                .rsplit("/", 1)[-1]
                .split("?")[0]
                .replace("discord_krisp-", "")
                .replace(".zip", ""),
                "hash": krisp_hash,
            }
            print(f"  OK: krisp for {platform.value}/{branch.value}")

        except Exception as exc:
            print(f"  Failed to fetch krisp for {platform.value}/{branch.value}: {exc}")

    with open(os.path.join(os.path.dirname(__file__), "sources.json"), "w") as f:
        json.dump(sources, f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
