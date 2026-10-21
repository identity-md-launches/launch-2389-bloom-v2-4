#!/usr/bin/env python3
"""Export deterministic ABIs and bytecode-template hashes. Requires only Python, Forge and Cast."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = {
    "BloomTreasury": "src/BloomTreasury.sol",
    "BloomFactory": "src/BloomFactory.sol",
    "StakedBLOOM": "src/StakedBLOOM.sol",
    "StakedSIMD": "src/StakedSIMD.sol",
    "StakedETH": "src/StakedETH.sol",
    "ERC20Farm": "src/core/ERC20Farm.sol",
}


def keccak(hexdata):
    return subprocess.check_output(["cast", "keccak", hexdata], text=True, cwd=ROOT).strip()


def rendered(value):
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if exported files differ")
    args = parser.parse_args()
    subprocess.run(["forge", "build", "--skip", "test", "--skip", "script"], cwd=ROOT, check=True)
    results = {
        "compiler": "0.8.26",
        "chainId": 1,
        "bytecodeHash": "none",
        "optimizerRuns": 200,
        "evmVersion": "cancun",
        "note": "Runtime hashes are compiler templates with zeroed immutable slots, NOT deployed hashes.",
        "contracts": {},
        "sourceSha256": {},
    }
    outputs = {}
    for name, source in CONTRACTS.items():
        artifact = json.loads((ROOT / "out" / Path(source).name / (name + ".json")).read_text())
        code = artifact["bytecode"]["object"]
        runtime = artifact["deployedBytecode"]["object"]
        assert not artifact["bytecode"].get("linkReferences"), "Unlinked creation code"
        assert not artifact["deployedBytecode"].get("linkReferences"), "Unlinked runtime"
        assert (len(runtime) - 2) // 2 <= 24_576
        assert (len(code) - 2) // 2 <= 49_152
        outputs[ROOT / "abi" / (name + ".json")] = rendered(artifact["abi"])
        results["contracts"][name] = {
            "source": source,
            "creationCodeKeccak256": keccak(code),
            "creationCodeBytesWithoutArguments": (len(code) - 2) // 2,
            "runtimeTemplateKeccak256": keccak(runtime),
            "runtimeBytes": (len(runtime) - 2) // 2,
            "immutableReferences": artifact["deployedBytecode"].get("immutableReferences", {}),
            "constructor": next(x for x in artifact["abi"] if x["type"] == "constructor"),
        }
    for folder in ["src", "script", "scripts"]:
        for path in sorted((ROOT / folder).rglob("*")):
            if path.is_file() and path.suffix in [".sol", ".py"]:
                results["sourceSha256"][str(path.relative_to(ROOT))] = hashlib.sha256(path.read_bytes()).hexdigest()
    for name in ["foundry.toml", "remappings.txt"]:
        results["sourceSha256"][name] = hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
    outputs[ROOT / "docs" / "artifact-hashes.json"] = rendered(results)
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit("Out-of-date export: " + str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    print("ABIs and hashes match." if args.check else "Exported ABIs and bytecode-template hashes.")


if __name__ == "__main__":
    main()
