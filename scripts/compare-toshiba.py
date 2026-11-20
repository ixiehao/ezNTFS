#!/usr/bin/env python3
"""Compare two mounts of TOSHIBA EXT using only generated data and a fresh output directory."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time


MIB = 1024 ** 2


def sample(sources):
    sources.mkdir()
    with (sources / "192MiB.bin").open("xb") as handle:
        for _ in range(192):
            handle.write(os.urandom(MIB))
    small = sources / "small-files"
    small.mkdir()
    for index in range(256):
        (small / f"file-{index:03d}.bin").write_bytes(os.urandom(4096 + index * 97))


def check_target(tool):
    inventory = subprocess.check_output([tool, "scan"], text=True).splitlines()
    candidates = [line.split("\t") for line in inventory if line.split("\t")[1:] == ["TOSHIBA EXT", "macfuse", "rw"]]
    if len(candidates) != 1:
        raise RuntimeError("需要唯一一个可读写的东芝盘。")
    partition = candidates[0][0]
    mounts = subprocess.check_output(["/sbin/mount"], text=True)
    match = re.search(rf"^/dev/r?{re.escape(partition)} on (/Volumes/[^\n]+) \(macfuse,([^\n]+)\)$", mounts, re.M)
    if not match or "read-only" in match[2]:
        raise RuntimeError("东芝盘的内核挂载状态与扫描结果不一致。")
    target = Path(match[1])
    if target.stat().st_dev == target.parent.stat().st_dev:
        raise RuntimeError("东芝盘挂载点已失效。")
    return partition, target


def compare(tool, backend, sources):
    partition, mount = check_target(tool)
    expected_device = mount.stat().st_dev
    overall = []
    speeds = []
    for name, copies in [("192MiB.bin", 3), ("small-files", 1)]:
        for index in range(copies):
            if check_target(tool) != (partition, mount) or mount.stat().st_dev != expected_device:
                raise RuntimeError("测试前目标挂载已变化。")
            from_file = sources / name
            with tempfile.TemporaryDirectory(prefix=".ezntfs-ab-", dir=mount) as folder:
                begin = time.monotonic()
                lines = subprocess.check_output([tool, "copy", partition, folder, str(from_file)], text=True).splitlines()
                end_to_end = time.monotonic() - begin
                if not lines[0].startswith("SHA-256 OK.") or not Path(lines[1]).is_relative_to(folder):
                    raise RuntimeError("校验输出无法确认。")
                print(f"{backend} {name} run={index + 1} end_to_end_s={end_to_end:.3f} {lines[0]}", flush=True)
                if name == "192MiB.bin":
                    overall.append(end_to_end)
                    speeds.append(float(lines[0].split("MiB/s=", 1)[1]))
    print(f"{backend} median_large_write_MiB_s={statistics.median(speeds):.3f} "
          f"median_large_total_s={statistics.median(overall):.3f}; target scratch removed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    create = commands.add_parser("prepare")
    create.add_argument("sources", type=Path)
    run = commands.add_parser("run")
    run.add_argument("tool")
    run.add_argument("backend", choices=["Nigate", "ezNTFS"])
    run.add_argument("sources", type=Path)
    args = parser.parse_args()
    if args.action == "prepare":
        sample(args.sources)
        print(f"192 MiB source SHA-256 {hashlib.file_digest((args.sources / '192MiB.bin').open('rb'), 'sha256').hexdigest()}")
    else:
        compare(args.tool, args.backend, args.sources)


if __name__ == "__main__":
    main()
