from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import tarfile
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
EXPORT_DIR = ROOT / "build" / "exports"
DIST_DIR = ROOT / "build" / "dist"
PAGES_DIR = ROOT / "build" / "pages"
VERSION_FILE = ROOT / "version.json"


@dataclass(frozen=True)
class Target:
    key: str
    source_path: Path
    executable_name: str
    archive_name: str
    archive_kind: str
    updater_script: Path


TARGETS = [
    Target(
        key="windows-x64",
        source_path=EXPORT_DIR / "windows-x64" / "BubbleTanks.exe",
        executable_name="BubbleTanks.exe",
        archive_name="bubble-tanks-windows-x64.zip",
        archive_kind="zip",
        updater_script=ROOT / "updater" / "install_update.ps1",
    ),
    Target(
        key="windows-arm64",
        source_path=EXPORT_DIR / "windows-arm64" / "BubbleTanks.exe",
        executable_name="BubbleTanks.exe",
        archive_name="bubble-tanks-windows-arm64.zip",
        archive_kind="zip",
        updater_script=ROOT / "updater" / "install_update.ps1",
    ),
    Target(
        key="linux-x64",
        source_path=EXPORT_DIR / "linux-x64" / "BubbleTanks.x86_64",
        executable_name="BubbleTanks.x86_64",
        archive_name="bubble-tanks-linux-x64.tar.gz",
        archive_kind="tar.gz",
        updater_script=ROOT / "updater" / "install_update.sh",
    ),
    Target(
        key="linux-arm64",
        source_path=EXPORT_DIR / "linux-arm64" / "BubbleTanks.arm64",
        executable_name="BubbleTanks.arm64",
        archive_name="bubble-tanks-linux-arm64.tar.gz",
        archive_kind="tar.gz",
        updater_script=ROOT / "updater" / "install_update.sh",
    ),
]


def load_version_info() -> dict:
    return json.loads(VERSION_FILE.read_text(encoding="utf-8"))


def repo_urls() -> tuple[str, str]:
    repository = os.getenv("GITHUB_REPOSITORY", "").strip()
    if not repository or "/" not in repository:
        return "", ""
    owner, repo = repository.split("/", 1)
    manifest_url = f"https://{owner}.github.io/{repo}/manifest.json"
    release_page = f"https://github.com/{repository}/releases/latest"
    return manifest_url, release_page


def rendered_version_info(version_info: dict, manifest_url: str, release_page: str) -> dict:
    rendered = dict(version_info)
    rendered["manifest_url"] = manifest_url
    rendered["release_page"] = release_page
    return rendered


def ensure_clean_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def sha256_for_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_zip_archive(source_dir: Path, destination: Path) -> None:
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source_dir.rglob("*")):
            if path.is_dir():
                continue
            archive.write(path, path.relative_to(source_dir))


def write_tar_gz_archive(source_dir: Path, destination: Path) -> None:
    with tarfile.open(destination, "w:gz") as archive:
        for path in sorted(source_dir.rglob("*")):
            archive.add(path, arcname=path.relative_to(source_dir))


def set_executable(path: Path) -> None:
    current_mode = path.stat().st_mode
    path.chmod(current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def package_target(target: Target, rendered_version: dict) -> dict:
    if not target.source_path.exists():
        raise FileNotFoundError(f"Missing exported binary for {target.key}: {target.source_path}")

    package_dir = DIST_DIR / target.key
    package_updater_dir = package_dir / "updater"
    package_updater_dir.mkdir(parents=True, exist_ok=True)

    executable_destination = package_dir / target.executable_name
    shutil.copy2(target.source_path, executable_destination)
    shutil.copy2(target.updater_script, package_updater_dir / target.updater_script.name)

    version_destination = package_dir / "version.json"
    version_destination.write_text(json.dumps(rendered_version, indent=2) + "\n", encoding="utf-8")

    if target.key.startswith("linux"):
        set_executable(executable_destination)
        set_executable(package_updater_dir / target.updater_script.name)

    archive_path = DIST_DIR / target.archive_name
    if target.archive_kind == "zip":
        write_zip_archive(package_dir, archive_path)
    else:
        write_tar_gz_archive(package_dir, archive_path)

    return {
        "filename": archive_path.name,
        "size": archive_path.stat().st_size,
        "sha256": sha256_for_file(archive_path),
    }


def build_manifest(version_info: dict, packaged_assets: dict[str, dict]) -> dict:
    repository = os.getenv("GITHUB_REPOSITORY", "").strip()
    release_tag = f"v{version_info['version']}"
    channel = version_info.get("channel", "stable")
    release_notes = os.getenv("RELEASE_NOTES", "").strip()
    channels: dict[str, dict] = {channel: {}}

    for target_key, asset in packaged_assets.items():
        asset_url = f"https://github.com/{repository}/releases/download/{release_tag}/{asset['filename']}" if repository else ""
        channels[channel][target_key] = {
            "url": asset_url,
            "filename": asset["filename"],
            "size": asset["size"],
            "sha256": asset["sha256"],
        }

    return {
        "latest_version": version_info["version"],
        "minimum_supported_version": version_info["version"],
        "channel": channel,
        "release_tag": release_tag,
        "release_notes": release_notes,
        "published_at": datetime.now(timezone.utc).isoformat(),
        "channels": channels,
    }


def write_checksums(packaged_assets: dict[str, dict]) -> None:
    lines = [f"{asset['sha256']}  {asset['filename']}" for asset in packaged_assets.values()]
    (DIST_DIR / "checksums.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    ensure_clean_dir(DIST_DIR)
    ensure_clean_dir(PAGES_DIR)

    version_info = load_version_info()
    manifest_url, release_page = repo_urls()
    rendered_version = rendered_version_info(version_info, manifest_url, release_page)

    packaged_assets: dict[str, dict] = {}
    for target in TARGETS:
        packaged_assets[target.key] = package_target(target, rendered_version)

    manifest = build_manifest(version_info, packaged_assets)
    (DIST_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (PAGES_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    write_checksums(packaged_assets)
    shutil.copy2(DIST_DIR / "checksums.txt", PAGES_DIR / "checksums.txt")


if __name__ == "__main__":
    main()