#!/usr/bin/env python3
"""Build lms-ytm.zip and a matching repo.xml (SHA1) for LMS plugin installs."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import zipfile
from pathlib import Path

PLUGIN_DIR = Path("Plugins") / "YouTubeMusic"
ZIP_NAME = "lms-ytm.zip"
SKIP_DIR_NAMES = {"__pycache__", "Bin"}
SKIP_SUFFIXES = {".pyc", ".pyo"}
SKIP_NAMES = {".ds_store"}


def xml_escape(text: str) -> str:
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def read_install_version(plugin_dir: Path) -> str:
    xml = (plugin_dir / "install.xml").read_text(encoding="utf-8")
    match = re.search(r"<version>\s*([^<]+?)\s*</version>", xml)
    if not match:
        raise SystemExit("install.xml has no <version>")
    return match.group(1).strip()


def first_tag(xml: str, name: str, default: str) -> str:
    match = re.search(rf"<{name}(?:\s[^>]*)?>(.*?)</{name}>", xml, re.DOTALL)
    if not match:
        return default
    return re.sub(r"\s+", " ", match.group(1)).strip()


def attr(xml: str, name: str, default: str) -> str:
    match = re.search(rf'\b{name}="([^"]*)"', xml)
    return match.group(1) if match else default


def catalog_fields(repo_xml: Path) -> dict[str, str]:
    defaults = {
        "repo_title": "YouTube Music for LMS",
        "title": "YouTube Music",
        "desc": (
            "Browse, search, and stream YouTube Music. "
            "Optional per-player account for library, history, and personalised home."
        ),
        "changes": "",
        "creator": "schmij97/OXipro",
        "category": "musicservices",
        "min_target": "9.0",
        "max_target": "*",
    }
    if not repo_xml.is_file():
        return defaults
    xml = repo_xml.read_text(encoding="utf-8")
    plugin = re.search(r"<plugin\b[^>]*>.*?</plugin>", xml, re.DOTALL)
    block = plugin.group(0) if plugin else xml
    details = re.search(r"<details\b[^>]*>.*?</details>", xml, re.DOTALL)
    details_xml = details.group(0) if details else ""
    return {
        "repo_title": first_tag(details_xml, "title", defaults["repo_title"]),
        "title": first_tag(block, "title", defaults["title"]),
        "desc": first_tag(block, "desc", defaults["desc"]),
        "changes": first_tag(block, "changes", defaults["changes"]),
        "creator": first_tag(block, "creator", defaults["creator"]),
        "category": first_tag(block, "category", defaults["category"]),
        "min_target": attr(block, "minTarget", defaults["min_target"]),
        "max_target": attr(block, "maxTarget", defaults["max_target"]),
    }


def should_skip(path: Path) -> bool:
    if path.name.lower() in SKIP_NAMES or path.suffix in SKIP_SUFFIXES:
        return True
    return any(part in SKIP_DIR_NAMES for part in path.parts)


def zip_members(plugin_dir: Path) -> list[Path]:
    files = [p for p in plugin_dir.rglob("*") if p.is_file() and not should_skip(p)]
    files.sort()
    if not files:
        raise SystemExit(f"no files under {plugin_dir}")
    if not (plugin_dir / "install.xml").is_file():
        raise SystemExit(f"missing {plugin_dir / 'install.xml'}")
    return files


def write_zip(plugin_dir: Path, zip_path: Path) -> None:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in zip_members(plugin_dir):
            arcname = path.as_posix()
            zf.write(path, arcname)


def sha1_file(path: Path) -> str:
    digest = hashlib.sha1()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_repo_xml(
    dest: Path,
    *,
    version: str,
    sha: str,
    url: str,
    fields: dict[str, str],
    changes: str,
) -> None:
    body = f"""<?xml version="1.0"?>
<extensions>
  <details>
    <title lang="EN">{xml_escape(fields["repo_title"])}</title>
  </details>
  <plugins>
    <plugin name="YouTubeMusic" version="{xml_escape(version)}" minTarget="{xml_escape(fields["min_target"])}" maxTarget="{xml_escape(fields["max_target"])}">
      <title lang="EN">{xml_escape(fields["title"])}</title>
      <desc lang="EN">{xml_escape(fields["desc"])}</desc>
      <changes lang="EN">{xml_escape(changes)}</changes>
      <creator>{xml_escape(fields["creator"])}</creator>
      <category>{xml_escape(fields["category"])}</category>
      <url>{xml_escape(url)}</url>
      <sha>{xml_escape(sha)}</sha>
    </plugin>
  </plugins>
</extensions>
"""
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(body, encoding="utf-8")


def default_changes(fields: dict[str, str], version: str) -> str:
    env = os.environ.get("PLUGIN_CHANGES", "").strip()
    if env:
        return env
    if fields["changes"]:
        return fields["changes"]
    return f"{version}: See the GitHub release notes."


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default="dist", help="output directory (default: dist)")
    parser.add_argument(
        "--repo",
        default=os.environ.get("GITHUB_REPOSITORY", "OXipro/lms-ytm"),
        help="GitHub owner/name for release asset URLs",
    )
    parser.add_argument(
        "--tag",
        default=os.environ.get("GITHUB_REF_NAME", ""),
        help="git tag; must be v plus install.xml version",
    )
    parser.add_argument(
        "--repo-xml",
        default="repo.xml",
        help="catalog metadata source (titles, changes)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    plugin_dir = PLUGIN_DIR
    if not plugin_dir.is_dir():
        raise SystemExit(f"missing {plugin_dir} (run from the repo root)")

    version = read_install_version(plugin_dir)
    tag = args.tag.strip()
    if tag and tag != f"v{version}":
        raise SystemExit(f"tag {tag} does not match install.xml version {version}")

    out = Path(args.out)
    zip_path = out / ZIP_NAME
    write_zip(plugin_dir, zip_path)
    sha = sha1_file(zip_path)
    url = f"https://github.com/{args.repo}/releases/download/v{version}/{ZIP_NAME}"
    fields = catalog_fields(Path(args.repo_xml))
    changes = default_changes(fields, version)
    write_repo_xml(
        out / "repo.xml",
        version=version,
        sha=sha,
        url=url,
        fields=fields,
        changes=changes,
    )
    print(f"version {version}")
    print(f"zip     {zip_path} ({zip_path.stat().st_size} bytes)")
    print(f"sha1    {sha}")
    print(f"url     {url}")
    print(f"repo    {out / 'repo.xml'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
