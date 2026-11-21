#!/usr/bin/env python3

import plistlib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "Sources/EzNTFSApp"
INSTALLER = ROOT / "scripts/installer"
LANGUAGES = {"en", "zh-Hans", "ja"}
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?@")
INSTALLER_TOKEN = re.compile(r"\{[a-z]+\}")


def check_catalogs(root, filename):
    folders = {folder.stem: folder for folder in root.glob("*.lproj")}
    if set(folders) != LANGUAGES:
        raise SystemExit(f"{root}: expected locale folders {sorted(LANGUAGES)}")
    catalogs = {}
    for language, folder in folders.items():
        path = folder / filename
        data = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)])
        strings = plistlib.loads(data)
        if not strings or any(not isinstance(value, str) or not value.strip() for value in strings.values()):
            raise SystemExit(f"{path}: empty translation")
        catalogs[language] = strings

    english = catalogs["en"]
    for language, strings in catalogs.items():
        if strings.keys() != english.keys():
            raise SystemExit(f"{language}/{filename}: key mismatch {sorted(strings.keys() ^ english.keys())}")
        for key, value in strings.items():
            if (sorted(PLACEHOLDER.findall(value)) != sorted(PLACEHOLDER.findall(english[key]))
                    or sorted(INSTALLER_TOKEN.findall(value)) != sorted(INSTALLER_TOKEN.findall(english[key]))):
                raise SystemExit(f"{language}/{filename}: format argument mismatch for {key}")
            if "%" in PLACEHOLDER.sub("", value):
                raise SystemExit(f"{language}/{filename}: unexpected format in {key}")
    return set(english)


app_keys = check_catalogs(APP / "Resources", "Localizable.strings")
swift = "\n".join(path.read_text(encoding="utf-8") for path in APP.glob("*.swift"))
prefixes = "|".join(sorted({re.escape(key.split(".")[0]) for key in app_keys}))
used = set(re.findall(r'"((?:' + prefixes + r')\.[\w.]+)"', swift))
if used != app_keys:
    raise SystemExit(f"App localization keys differ from Swift usage: {sorted(used ^ app_keys)}")

if check_catalogs(APP / "Resources", "InfoPlist.strings") != {"NSRemovableVolumesUsageDescription"}:
    raise SystemExit("Missing localized removable-volume permission description")

installer_keys = check_catalogs(INSTALLER / "Resources", "Localizable.strings")
distribution = (INSTALLER / "Distribution.xml.in").read_text(encoding="utf-8")
if installer_keys != set(re.findall(r'system\.localizedString\("([^"]+)"\)', distribution)):
    raise SystemExit("Installer localization keys differ from Distribution.xml")
for language in LANGUAGES:
    welcome = (INSTALLER / "Resources" / f"{language}.lproj" / "Welcome.html").read_text(encoding="utf-8")
    if f'<html lang="{language}">' not in welcome:
        raise SystemExit(f"{language}: installer welcome language mismatch")

print(f"{len(app_keys)} App strings and {len(installer_keys)} installer strings verified in {len(LANGUAGES)} languages.")
