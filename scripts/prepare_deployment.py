#!/usr/bin/env python3
"""Produce one unsigned creation transaction. Never signs, submits, or reads wallet configuration."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OWNER = "0xDEA11b3A70b77134424d436f6eb455f1Abbd4449"


def cast(*args):
    return subprocess.check_output(["cast", *map(str, args)], cwd=ROOT, text=True).strip()


def address(value):
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value) or int(value, 16) == 0:
        raise argparse.ArgumentTypeError("A real nonzero contract address is required")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=["BloomTreasury", "BloomFactory", "StakedBLOOM", "StakedSIMD", "StakedETH"])
    parser.add_argument("--confirm-owner", required=True, type=address, help="must equal the supplied requester")
    parser.add_argument("--treasury", type=address)
    parser.add_argument("--registry", type=address)
    parser.add_argument("--bloom", type=address)
    parser.add_argument("--bloom-decimals", type=int)
    parser.add_argument("--rpc", help="public chain-1 RPC; required when an existing dependency is used")
    args = parser.parse_args()
    if args.confirm_owner.lower() != OWNER.lower():
        parser.error("Owner differs from the requester; no transaction prepared")
    contract = args.component
    inputs = [OWNER]
    types = ["address"]
    if contract != "BloomTreasury":
        if not args.treasury or not args.rpc:
            parser.error("--treasury and --rpc are required")
        if cast("chain-id", "--rpc-url", args.rpc) != "1":
            parser.error("RPC is not Ethereum chain 1")
        if cast("code", args.treasury, "--rpc-url", args.rpc) == "0x":
            parser.error("Treasury has no deployed code")
        if cast("call", args.treasury, "owner()(address)", "--rpc-url", args.rpc).lower() != OWNER.lower():
            parser.error("Requester does not own Treasury")
    if contract == "BloomFactory":
        inputs.append(args.treasury)
        types.append("address")
    elif contract.startswith("Staked"):
        if not args.registry or not args.bloom:
            parser.error("Real --registry and --bloom addresses are required; Job 2 must finish first")
        for dependency in [args.registry, args.bloom]:
            if cast("code", dependency, "--rpc-url", args.rpc) == "0x":
                parser.error("Farm dependency has no deployed code")
        checks = [("owner()(address)", OWNER), ("treasury()(address)", args.treasury), ("bloom()(address)", args.bloom)]
        for signature, expected in checks:
            if cast("call", args.registry, signature, "--rpc-url", args.rpc).lower() != expected.lower():
                parser.error("Registry check failed: " + signature)
        inputs += [args.registry, args.treasury, args.bloom]
        types += ["address", "address", "address"]
        if contract == "StakedBLOOM":
            actual = int(cast("call", args.bloom, "decimals()(uint8)", "--rpc-url", args.rpc))
            if args.bloom_decimals is None or args.bloom_decimals != actual or actual > 36:
                parser.error("--bloom-decimals must equal verified on-chain decimals, at most 36")
            inputs.append(str(actual))
            types.append("uint8")
    artifact_path = ROOT / "out" / (contract + ".sol") / (contract + ".json")
    if not artifact_path.exists():
        parser.error("Run forge build first")
    artifact = json.loads(artifact_path.read_text())
    encoded = cast("abi-encode", "constructor(" + ",".join(types) + ")", *inputs)
    initcode = artifact["bytecode"]["object"] + encoded[2:]
    plan = {
        "status": "unsigned; no transaction sent",
        "approvalRequired": "Explicit requester approval of THIS transaction before any submission",
        "contract": contract,
        "owner": OWNER,
        "constructorTypes": types,
        "constructorArguments": inputs,
        "encodedConstructorArguments": encoded,
        "initCodeKeccak256": cast("keccak", initcode),
        "unsignedTransaction": {"chainId": 1, "value": "0x0", "data": initcode},
        "transactionHash": None,
        "receipt": None,
        "gasUsed": None,
        "note": "No `to` means direct creation. For the launch service, use these constructor arguments and bytecode in its own reviewed factory transaction. Do not substitute a caller for the owner.",
    }
    print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    main()
