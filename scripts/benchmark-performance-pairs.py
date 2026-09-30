#!/usr/bin/env python3
"""Five alternating pairs for the prepared local timeline/inspection/preview drivers."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess


def run_case(options):
    root = Path(options.root).resolve()
    names = ("timeline", "inspection", "preview")
    if options.case not in names:
        raise ValueError("Unknown benchmark case")
    versions = ("baseline", "current")
    binaries = {version: root / f"{options.case}-{version}" for version in versions}
    if options.case == "timeline":
        binaries["baseline"] = binaries["current"]
    for binary in binaries.values():
        if not binary.is_file():
            raise FileNotFoundError(f"Compile the prepared benchmark driver first: {binary}")
    fixture = root / ("inspection-fixture-v2" if options.case == "inspection" else "preview-fixture")
    if options.case != "timeline":
        subprocess.run([str(binaries["current"]), str(fixture), "prepare"], check=True)
    groups = (24, 240) if options.case == "timeline" else (
        ("audio", False), ("audio", True), ("transcript", False), ("transcript", True)
    ) if options.case == "inspection" else (False, True)
    output = root / f"{options.case}-final-pairs.jsonl"
    partial = output.with_suffix(".partial.jsonl")
    summaries = []
    with partial.open("w") as stream:
        for group in groups:
            samples = []
            for pair in range(1, 6):
                for version in versions if pair % 2 else tuple(reversed(versions)):
                    args = [str(binaries[version])]
                    if options.case == "timeline":
                        args += ["baseline" if version == "baseline" else "viewport", str(group)]
                    else:
                        args += [str(fixture)]
                        warm = group[1] if options.case == "inspection" else group
                        if options.case == "inspection":
                            args += [group[0]]
                        if warm:
                            args += ["warm"]
                    result = subprocess.run(args, capture_output=True, text=True, check=True)
                    sample = json.loads(result.stdout.strip().splitlines()[-1])
                    sample.update(pair=pair, version=version)
                    samples.append(sample)
                    stream.write(json.dumps(sample, sort_keys=True) + "\n")
                    stream.flush()
            if options.case in ("timeline", "inspection"):
                if len({sample["digest"] for sample in samples}) != 1:
                    raise ValueError(f"Output changed in {group}")
            if options.case == "inspection":
                if any(sample["waveformFiles"] != (5 if sample["version"] == "baseline" else 1) for sample in samples):
                    raise ValueError("Unexpected source loading count")
            if options.case == "preview":
                if len({(s["duration"], s["frameWidth"], s["frameHeight"]) for s in samples}) != 1:
                    raise ValueError("Preview geometry changed")
                if any(s["builds"] != (10 if s["version"] == "baseline" else 0) for s in samples):
                    raise ValueError("Unexpected preview rebuild count")
            summary = {"group": group}
            for version in versions:
                selected = [sample for sample in samples if sample["version"] == version]
                summary[version] = {key: statistics.median(sample[key] for sample in selected)
                                    for key in ("seconds", "cpuSeconds", "peakRSSBytes")}
                summary[version]["minSeconds"] = min(sample["seconds"] for sample in selected)
                summary[version]["maxSeconds"] = max(sample["seconds"] for sample in selected)
            summaries.append(summary)
            print(json.dumps(summary, sort_keys=True), flush=True)
    partial.replace(output)
    metadata = {"case": options.case, "pairedRunsPerGroup": 5, "summaries": summaries,
                "driverSHA256": {version: hashlib.sha256(binary.read_bytes()).hexdigest()
                                 for version, binary in binaries.items()},
                "cpuScope": "whole fresh process, including preparation and warmup",
                "cacheScope": "waveform disk/RAM caches only; OS file cache is not flushed"}
    output.with_suffix(".summary.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=("timeline", "inspection", "preview"))
    parser.add_argument("--root", default=".build/performance-review")
    run_case(parser.parse_args())
