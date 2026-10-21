#!/usr/bin/env python3
"""Read-only dependency revalidation at one Ethereum block. Does not sign or submit transactions."""
import argparse
import concurrent.futures
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def cast(*args):
    return subprocess.check_output(["cast", *map(str, args)], cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--block", type=int)
    args = parser.parse_args()
    if cast("chain-id", "--rpc-url", args.rpc) != "1":
        parser.error("Expected Ethereum chain 1")
    block = args.block or int(cast("block-number", "--rpc-url", args.rpc))
    pinned = json.loads((ROOT / "docs/evidence/mainnet-reads.json").read_text())
    suffix = ["--rpc-url", args.rpc, "--block", str(block), "--rpc-timeout", "20"]

    def verify(item):
        name, addr = item
        code = cast("code", addr, *suffix)
        codehash = cast("keccak", code)
        expected = pinned["reads"][name + ":code"]["keccak256"]
        if codehash != expected:
            raise RuntimeError(name + " code differs from the verified dependency")
        decimals = cast("call", addr, "decimals()(uint8)", *suffix)
        if decimals != ("24" if name == "sIMD" else "18"):
            raise RuntimeError(name + " decimals differ")
        return name, {"address": addr, "codeHash": codehash, "decimals": decimals,
                      "symbol": cast("call", addr, "symbol()(string)", *suffix)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        result = dict(executor.map(verify, pinned["addresses"].items()))
    vault = pinned["addresses"]["sIMD"]
    for signature in ["asset()(address)", "owner()(address)", "paused()(bool)", "totalAssets()(uint256)", "totalSupply()(uint256)"]:
        result["sIMD"][signature] = cast("call", vault, signature, *suffix)
    if result["sIMD"]["asset()(address)"].lower() != pinned["addresses"]["IMD"].lower():
        raise RuntimeError("sIMD underlying mismatch")
    result["sIMD"]["IMD per 1 sIMD (raw)"] = cast("call", vault, "convertToAssets(uint256)(uint256)", 10**24, *suffix)
    result["sIMD"]["sIMD per 1 IMD (raw)"] = cast("call", vault, "convertToShares(uint256)(uint256)", 10**18, *suffix)
    print(json.dumps({"chainId": 1, "block": block, "dependencies": result}, indent=2))


if __name__ == "__main__":
    main()
