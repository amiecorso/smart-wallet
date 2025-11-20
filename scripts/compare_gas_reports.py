#!/usr/bin/env python3
import argparse
import os
import re
from typing import Dict, List, Tuple


def _to_int(s: str) -> int:
    digits = re.sub(r"[^0-9]", "", s)
    return int(digits) if digits else 0


def _split_row(line: str) -> List[str]:
    # Rows are like: | field | field | ... |
    # Keep inner cells trimmed; ignore first and last borders.
    parts = [p.strip() for p in line.strip().split("|")]
    # drops leading '' (before first |) and trailing '' (after last |) if present
    if parts and parts[0] == "":
        parts = parts[1:]
    if parts and parts[-1] == "":
        parts = parts[:-1]
    return parts


def parse_contract_section(lines: List[str], contract_header: str) -> Tuple[int, int, Dict[str, Dict[str, int]]]:
    """
    Returns (deployment_cost, deployment_size, functions) for the given contract.
    Each function entry is a dict with keys: min, avg, median, max, calls.
    """
    # Find the contract header row
    header_idx = -1
    for i, line in enumerate(lines):
        if line.find(contract_header) != -1:
            header_idx = i
            break
    if header_idx == -1:
        raise ValueError(f"Contract section not found: {contract_header}")

    deployment_cost = 0
    deployment_size = 0
    functions: Dict[str, Dict[str, int]] = {}

    i = header_idx
    # Scan until we hit the closing border of this section
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith("╰"):
            break

        # Detect the deployment header row, next line has values
        if "Deployment Cost" in line and "Deployment Size" in line:
            if i + 2 < len(lines):
                value_row = lines[i + 2] if lines[i + 1].strip().startswith("|---") else lines[i + 1]
                cells = _split_row(value_row)
                # Expect first two cells to be numbers (cost and size)
                if len(cells) >= 2:
                    deployment_cost = _to_int(cells[0])
                    deployment_size = _to_int(cells[1])
            i += 1
            continue

        # Detect function table header
        if "Function Name" in line and "Avg" in line:
            # Read subsequent rows until a border or blank
            j = i + 1
            while j < len(lines):
                row = lines[j].rstrip("\n")
                if not row.strip().startswith("|"):
                    break
                # Skip header separators
                if set(row.replace("|", "").strip()) <= set("-+"):
                    j += 1
                    continue
                cells = _split_row(row)
                if not cells:
                    break
                # Expected: [name, Min, Avg, Median, Max, # Calls]
                # Some reports may have minor spacing differences; guard by indexes.
                name = cells[0]
                try:
                    fn = {
                        "min": _to_int(cells[1]) if len(cells) > 1 else 0,
                        "avg": _to_int(cells[2]) if len(cells) > 2 else 0,
                        "median": _to_int(cells[3]) if len(cells) > 3 else 0,
                        "max": _to_int(cells[4]) if len(cells) > 4 else 0,
                        "calls": _to_int(cells[5]) if len(cells) > 5 else 0,
                    }
                    functions[name] = fn
                except Exception:
                    pass
                j += 1
            i = j
            continue

        i += 1

    return deployment_cost, deployment_size, functions


def format_markdown_delta(
    label_a: str,
    label_b: str,
    a_cost: int,
    b_cost: int,
    a_size: int,
    b_size: int,
    a_funcs: Dict[str, Dict[str, int]],
    b_funcs: Dict[str, Dict[str, int]],
    functions_filter: List[str] = None,
) -> str:
    def pct_delta(a: int, b: int) -> str:
        if a == 0:
            return "n/a"
        return f"{((b - a) / a) * 100:.1f}%"

    lines = []
    lines.append(f"| Metric | {label_a} | {label_b} | Δ (abs) | Δ (%) |")
    lines.append(f"|---|---:|---:|---:|---:|")
    lines.append(
        f"| Deployment Gas | {a_cost:,} | {b_cost:,} | {b_cost - a_cost:+,} | {pct_delta(a_cost, b_cost)} |"
    )
    lines.append(
        f"| Deployment Size (bytes) | {a_size:,} | {b_size:,} | {b_size - a_size:+,} | {pct_delta(a_size, b_size)} |"
    )
    lines.append("")
    lines.append(f"| Function (Avg gas) | {label_a} | {label_b} | Δ (abs) | Δ (%) |")
    lines.append(f"|---|---:|---:|---:|---:|")

    # Union of function names (optionally filtered)
    fn_names = sorted(set(a_funcs.keys()) | set(b_funcs.keys()))
    if functions_filter:
        fn_names = [n for n in fn_names if n in functions_filter]

    for name in fn_names:
        a_avg = a_funcs.get(name, {}).get("avg", 0)
        b_avg = b_funcs.get(name, {}).get("avg", 0)
        lines.append(f"| {name} | {a_avg:,} | {b_avg:,} | {b_avg - a_avg:+,} | {pct_delta(a_avg, b_avg)} |")

    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Compare two Foundry gas reports for a target contract.")
    parser.add_argument("report_a", help="Path to first gas report (e.g. artifacts/default/gas-report.txt)")
    parser.add_argument("report_b", help="Path to second gas report (e.g. artifacts/deploy/gas-report.txt)")
    parser.add_argument(
        "--contract",
        required=True,
        help='Contract selector as it appears in report header, e.g. "src/CoinbaseSmartWallet.sol:CoinbaseSmartWallet"',
    )
    parser.add_argument(
        "--functions",
        help="Comma-separated list of function names to include (optional). Defaults to all functions in section.",
    )
    parser.add_argument("--label-a", default="default", help="Label for first report (default: default)")
    parser.add_argument("--label-b", default="deploy", help="Label for second report (default: deploy)")
    parser.add_argument("--out", help="Optional output file path for markdown table")
    args = parser.parse_args()

    with open(args.report_a, "r", encoding="utf-8") as fa:
        lines_a = fa.readlines()
    with open(args.report_b, "r", encoding="utf-8") as fb:
        lines_b = fb.readlines()

    # In report, header includes " Contract" suffix. Match exactly as printed.
    contract_header = f"{args.contract} Contract"
    a_cost, a_size, a_funcs = parse_contract_section(lines_a, contract_header)
    b_cost, b_size, b_funcs = parse_contract_section(lines_b, contract_header)

    functions_filter = [f.strip() for f in args.functions.split(",")] if args.functions else None
    md = format_markdown_delta(
        args.label_a, args.label_b, a_cost, b_cost, a_size, b_size, a_funcs, b_funcs, functions_filter
    )

    if args.out:
        os.makedirs(os.path.dirname(args.out), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as fo:
            fo.write(md)
    else:
        print(md, end="")


if __name__ == "__main__":
    main()



