#!/usr/bin/env python3
"""Build the static ezNTFS Pages artifact from one content file."""

import argparse
from datetime import date
from hashlib import sha256
from html import escape
import json
from pathlib import Path
import re
from string import Template
from xml.etree import ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "website"
SITE = "https://ixiehao.github.io/ezNTFS/"
REPO = "https://github.com/ixiehao/ezNTFS"
LANG_TAGS = {"en": "en", "zh-Hans": "zh-CN", "ja": "ja"}
WORKFLOW = (("mount", "plug-connected", 206), ("copy", "copy", 280), ("eject", "player-eject", 124))

data = json.loads((SOURCE / "content.json").read_text(encoding="utf-8"))
languages = data["languages"]
if set(languages) != set(LANG_TAGS) or any(
    copy.keys() != languages["en"].keys() for copy in languages.values()
):
    raise SystemExit("Website translation keys must match the English page.")
version = data["version"]
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Expected a stable release version.")
intel_preview_version = data["intelPreviewVersion"]
if not re.fullmatch(r"\d+\.\d+\.\d+-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*", intel_preview_version):
    raise SystemExit("Expected an Intel preview version with a prerelease suffix.")
last_modified = date.fromisoformat(data["lastModified"]).isoformat()
release = f"{REPO}/releases/tag/v{version}"
intel_preview = f"{REPO}/releases/tag/v{intel_preview_version}"
intel_download = f"{REPO}/releases/download/v{intel_preview_version}/ezNTFS-{intel_preview_version}-x86_64.pkg"
assets = f"{REPO}/releases/download/v{version}"
download = f"{assets}/ezNTFS-{version}-arm64.pkg"
checksum = f"{assets}/SHA256SUMS.txt"
macfuse = f"https://github.com/macfuse/macfuse/releases/tag/macfuse-{data['macFUSE']}"
template = Template((SOURCE / "index.template.html").read_text(encoding="utf-8"))
css = (SOURCE / "styles.css").read_bytes()
files = {
    ".nojekyll": b"",
    "styles.css": css,
    "assets/ezntfs.svg": (ROOT / "Resources/Brand/AppIcon.svg").read_bytes(),
    "assets/Tabler-Icons-LICENSE.txt": (ROOT / "Resources/Tabler/LICENSE").read_bytes(),
}
asset_key = sha256(css).hexdigest()[:12]


def icon(name):
    path = ROOT / "Resources/Tabler.xcassets" / f"{name}.imageset" / f"{name}.svg"
    svg = path.read_text(encoding="utf-8")
    return svg[svg.index("<svg"):].replace("<svg", '<svg aria-hidden="true" focusable="false"', 1)


def canonical(lang):
    return SITE + languages[lang]["directory"]


def alternate_links():
    links = [f'<link rel="alternate" hreflang="{LANG_TAGS[lang]}" href="{canonical(lang)}">'
             for lang in languages]
    return "\n  ".join(links + [f'<link rel="alternate" hreflang="x-default" href="{SITE}">'])


def language_links(lang):
    prefix = "../" if languages[lang]["directory"] else "./"
    return "\n        ".join(
        f'<a href="{prefix}{copy["directory"]}" hreflang="{LANG_TAGS[code]}" lang="{LANG_TAGS[code]}"'
        + (' aria-current="page"' if lang == code else "")
        + f'>{escape(copy["name"])}</a>'
        for code, copy in languages.items()
    )


def render(lang, copy):
    screenshot = f"assets/ezntfs-{lang}.png"
    files[screenshot] = (SOURCE / screenshot).read_bytes()
    schema = {
        "@context": "https://schema.org", "@type": "SoftwareApplication",
        "name": "ezNTFS", "description": copy["description"], "url": canonical(lang),
        "inLanguage": LANG_TAGS[lang], "softwareVersion": version, "downloadUrl": download,
        "operatingSystem": f"macOS {data['minimumMacOS']}+ (Apple Silicon)",
        "screenshot": SITE + screenshot, "applicationCategory": "UtilitiesApplication",
        "license": f"{REPO}/blob/main/LICENSE",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    }
    prefix = ".." if copy["directory"] else "."
    if len(copy["workflow"]) != len(WORKFLOW):
        raise SystemExit(f"Expected {len(WORKFLOW)} workflow steps for {lang}.")
    workflow_steps = []
    workflow_markdown = []
    for (step, icon_name, height), (title, body, alt) in zip(WORKFLOW, copy["workflow"]):
        image_path = f"assets/guide/{step}-{lang}.png"
        files[image_path] = (SOURCE / image_path).read_bytes()
        image_url = f"{prefix}/{image_path}"
        workflow_steps.append(
            f'<article class="workflow-step"><div><h3><span class="card-icon">{icon(icon_name)}</span>'
            f'{escape(title)}</h3><p>{escape(body)}</p></div>'
            f'<a class="step-shot" href="{image_url}"><img src="{image_url}" width="600" height="{height}"'
            f' alt="{escape(alt)}" loading="lazy" decoding="async"></a></article>'
        )
        workflow_markdown.extend([f'### {title}', "", body, "", f'![{alt}]({image_url})', ""])
    question_html = [
        f"<details><summary>{escape(question)}</summary><p>{escape(answer)}</p></details>"
        for question, answer in copy["questions"]
    ]
    steps = [step.format(fuse=data["macFUSE"]) for step in copy["installSteps"]]
    heading_first, heading_second = copy["heading"]
    text = {key: escape(value) for key, value in copy.items() if isinstance(value, str)}
    document = template.substitute(
        **{
            **text,
            "lang": LANG_TAGS[lang], "canonical": canonical(lang),
            "prefix": prefix, "alternates": alternate_links(),
            "language_links": language_links(lang), "share_image": SITE + screenshot,
            "screenshot": screenshot, "screenshot_alt": text["screenshotAlt"],
            "screenshot_label": text["screenshotLabel"],
            "schema": json.dumps(schema, ensure_ascii=False).replace("<", "\\u003c"),
            "repository": REPO, "asset_key": asset_key, "version": version,
            "requirements": text["requirements"].format(macos=data["minimumMacOS"]),
            "heading_first": escape(heading_first), "heading_second": escape(heading_second),
            "release_url": release, "download_url": download, "checksum_url": checksum,
            "intel_preview_url": intel_preview, "intel_download_url": intel_download,
            "intel_preview_version": intel_preview_version,
            "workflow_title": text["workflowTitle"],
            "workflow_steps": "\n        ".join(workflow_steps), "questions": "\n      ".join(question_html),
            "install_title": text["installTitle"], "sign_title": text["signTitle"],
            "macfuse_link": text["macfuseLink"],
            "macfuse_missing": text["macfuseMissing"],
            "macfuse_once": text["macfuseOnce"].format(fuse=data["macFUSE"]), "macfuse_url": macfuse,
            "install_steps": "\n            ".join(f"<li>{escape(step)}</li>" for step in steps),
        }
    )
    markdown = [
        f'# {copy["title"]}', "", copy["intro"], "", f'## {copy["downloadTitle"]}', "",
        f'- {copy["stableChip"]} · {copy["stableLabel"]} · v{version} · '
        f'[{copy["download"]}]({download}) · [{copy["release"]}]({release})',
        f'- Intel Mac · {copy["previewLabel"]} · v{intel_preview_version} · '
        f'[{copy["intelPreviewLink"]}]({intel_download}) · [{copy["release"]}]({intel_preview})',
        "", copy["intelPreviewNote"], "", f'## {copy["workflowTitle"]}', "", copy["guideNote"], "",
        *workflow_markdown,
        f'## {copy["installTitle"]}', "", copy["requirements"].format(macos=data["minimumMacOS"]),
        "", *[f"{i}. {step}" for i, step in enumerate(steps, 1)], "",
        copy["macfuseOnce"].format(fuse=data["macFUSE"]),
        f'[{copy["macfuseLink"]}]({macfuse})', "",
        copy["signing"], "", copy["upgrade"], "",
        f'[{copy["checksum"]}]({checksum})',
        "", f'## {copy["faq"]}', "",
        *[f"**{question}**  \n{answer}\n" for question, answer in copy["questions"]],
    ]
    files[copy["directory"] + "index.html"] = document.encode()
    files[copy["directory"] + "index.md"] = ("\n".join(markdown) + "\n").encode()


for lang, copy in languages.items():
    render(lang, copy)

sitemap = ET.Element("urlset", xmlns="http://www.sitemaps.org/schemas/sitemap/0.9")
for lang in languages:
    entry = ET.SubElement(sitemap, "url")
    ET.SubElement(entry, "loc").text = canonical(lang)
    ET.SubElement(entry, "lastmod").text = last_modified
files["sitemap.xml"] = ET.tostring(sitemap, encoding="utf-8", xml_declaration=True) + b"\n"
files["llms.txt"] = (
    f'# ezNTFS\n\n> {languages["en"]["description"]}\n\n'
    + "\n".join(f'- [{copy["name"]}]({canonical(lang)}index.md)' for lang, copy in languages.items())
    + f"\n- [Source and documentation]({REPO})\n- [Stable release for Apple silicon]({release})"
    + f"\n- [Intel Mac preview]({intel_preview})\n"
).encode()
verification_key = (SOURCE / "indexnow-key.txt").read_text(encoding="utf-8").strip()
if not re.fullmatch(r"[0-9a-f]{32}", verification_key):
    raise SystemExit("Invalid IndexNow verification key.")
files[f"{verification_key}.txt"] = verification_key.encode()
files["404.html"] = (
    '<!doctype html><html lang="en"><meta charset="utf-8">'
    '<meta name="viewport" content="width=device-width, initial-scale=1">'
    '<title>Page not found · ezNTFS</title>'
    f'<link rel="stylesheet" href="{SITE}styles.css"><main class="wrap questions">'
    '<h1>Page not found</h1><div><p>ページが見つかりません · 找不到页面</p><nav>'
    + "".join(f'<a href="{canonical(lang)}" lang="{LANG_TAGS[lang]}">{escape(copy["name"])}</a>'
              for lang, copy in languages.items())
    + "</nav></div></main></html>\n"
).encode()

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=ROOT / "dist/website")
parser.add_argument("--check", action="store_true", help="Check without rewriting generated files.")
args = parser.parse_args()
existing = {p.relative_to(args.output).as_posix() for p in args.output.rglob("*") if p.is_file()}
if existing - files.keys():
    raise SystemExit(f"Unexpected site output files: {sorted(existing - files.keys())}")
for name, content in files.items():
    target = args.output / name
    if args.check:
        if not target.is_file() or target.read_bytes() != content:
            raise SystemExit(f"Missing or stale site output: {name}")
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
print(f"{len(languages)} localized pages, {len(files)} publishable files.")
