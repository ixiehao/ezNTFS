"""Render @2x Monterey icon templates from the same SVG originals as the asset catalog."""

import re
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


def render(source: Path, temporary: Path, output: Path) -> None:
    svg = source.read_text(encoding="utf-8")
    svg, count = re.subn(r'\b(width|height)="([0-9]+)"',
                         lambda match: f'{match[1]}="{int(match[2]) * 2}"', svg, count=2)
    if count != 2:
        raise ValueError(f"Missing SVG dimensions: {source}")
    temporary.write_text(svg, encoding="utf-8")
    subprocess.run(
        ["/usr/bin/sips", "-s", "format", "png", str(temporary), "--out", str(output / (source.stem + ".png"))],
        check=True, stdout=subprocess.DEVNULL,
    )


if __name__ == "__main__":
    output = Path(sys.argv[1])
    with TemporaryDirectory(prefix="ezntfs-icons-") as folder:
        temporary = Path(folder) / "icon.svg"
        for catalog in ("Tabler", "Brand"):
            for source in sorted(Path(f"Resources/{catalog}.xcassets").glob("*.imageset/*.svg")):
                render(source, temporary, output)
