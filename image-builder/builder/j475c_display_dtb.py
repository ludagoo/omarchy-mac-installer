#!/usr/bin/env python3
"""Verify the J475c Mac Studio multi-display device-tree wiring (dcpext0-3).

The Mac Studio (M2 Max, j475c) needs dcpext2 and dcpext3 wired alongside
dcpext0 (HDMI) and dcpext1 (USB-C) so three monitors work in any combination.
In the raw DTB, m2_dcpext2 and m2_dcpext3 must stay status = "disabled"
because aura reserves their firmware and flips them to "okay" only when
their IOPs exist in the ADT; an "okay" dcpext without firmware stalls
typec_mux_match() across all four rear USB-C ports.

    j475c_display_dtb.py DTB          exit 0 when J475c multi-display DT checks pass
"""
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class Node:
    path: str
    props: dict[str, str] = field(default_factory=dict)
    children: dict[str, "Node"] = field(default_factory=dict)


def parse_dts(dts: str) -> Node:
    root = Node("/")
    stack = [root]
    for raw in dts.splitlines():
        line = raw.strip()
        if not line or line.startswith("/dts-v1/"):
            continue
        if line == "/ {":
            continue
        if line.endswith("{"):
            name = line[:-1].strip()
            parent = stack[-1]
            child_path = "/" + name if parent.path == "/" else f"{parent.path}/{name}"
            node = parent.children.setdefault(name, Node(child_path))
            stack.append(node)
        elif line == "};":
            if len(stack) > 1:
                stack.pop()
        elif line.endswith(";"):
            body = line[:-1]
            if " = " in body:
                k, v = body.split(" = ", 1)
                stack[-1].props[k.strip()] = v.strip()
            else:
                stack[-1].props[body.strip()] = ""
    return root


def index_nodes(node: Node, by_path: dict[str, Node], by_phandle: dict[int, Node]) -> None:
    by_path[node.path] = node
    ph = node.props.get("phandle")
    if ph:
        cells = parse_cells(ph)
        if len(cells) == 1:
            by_phandle[cells[0]] = node
    for child in node.children.values():
        index_nodes(child, by_path, by_phandle)


def parse_cells(val: str) -> list[int]:
    m = re.fullmatch(r"<([^>]*)>", val.strip())
    if not m:
        raise ValueError(f"expected cell array, got {val!r}")
    out = []
    for tok in m.group(1).split():
        out.append(int(tok, 16 if tok.startswith(("0x", "0X")) else 10))
    return out


def parse_strings(val: str) -> list[str]:
    return re.findall(r'"([^"]*)"', val)


def decompile_dtb(path: Path) -> str:
    res = subprocess.run(
        ["dtc", "-I", "dtb", "-O", "dts", "-q", str(path)],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"dtc failed on {path}: {res.stderr.strip()}")
    return res.stdout


def check_dtb(path: Path) -> list[str]:
    errors: list[str] = []
    root = parse_dts(decompile_dtb(path))
    by_path: dict[str, Node] = {}
    by_phandle: dict[int, Node] = {}
    index_nodes(root, by_path, by_phandle)

    def req(node_path: str) -> Node | None:
        node = by_path.get(node_path)
        if node is None:
            errors.append(f"missing node {node_path}")
        return node

    def str_prop(node: Node | None, key: str) -> list[str]:
        if node is None or key not in node.props:
            if node is not None:
                errors.append(f"{node.path}: missing property {key}")
            return []
        return parse_strings(node.props[key])

    def cell_prop(node: Node | None, key: str) -> list[int]:
        if node is None or key not in node.props:
            if node is not None:
                errors.append(f"{node.path}: missing property {key}")
            return []
        try:
            return parse_cells(node.props[key])
        except ValueError as exc:
            errors.append(f"{node.path}: {key}: {exc}")
            return []

    aliases = req("/aliases")
    if aliases is not None:
        if "dcp" in aliases.props:
            errors.append("/aliases: dcp alias must be absent on j475c")
        expected_aliases = {
            "dcpext0": "/soc/dcp@289c00000",
            "dcpext1": "/soc/dcp@315c00000",
            "dcpext2": "/soc/dcp@48dc00000",
            "dcpext3": "/soc/dcp@50dc00000",
        }
        for name, target in expected_aliases.items():
            got = str_prop(aliases, name)
            if got != [target]:
                errors.append(f"/aliases: {name} expected [{target}], got {got}")

    for clk_path, clk_name in [
        ("/clock-dispext2", "clk_dispext2"),
        ("/clock-dispext3", "clk_dispext3"),
    ]:
        clk = req(clk_path)
        if clk is not None:
            if str_prop(clk, "compatible") != ["fixed-clock"]:
                errors.append(f"{clk_path}: unexpected compatible")
            if str_prop(clk, "clock-output-names") != [clk_name]:
                errors.append(f"{clk_path}: unexpected clock-output-names")

    for dart_path in [
        "/soc/iommu@48d304000",
        "/soc/iommu@48d30c000",
        "/soc/iommu@50d304000",
        "/soc/iommu@50d30c000",
    ]:
        dart = req(dart_path)
        if dart is not None:
            if str_prop(dart, "status") != ["okay"]:
                errors.append(f"{dart_path}: status must be okay")
            if cell_prop(dart, "apple,dma-range") != [0x100, 0x0, 0x10, 0x0]:
                errors.append(f"{dart_path}: apple,dma-range must be <0x100 0 0x10 0>")

    for mbox_path in ["/soc/mailbox@48dc08000", "/soc/mailbox@50dc08000"]:
        mbox = req(mbox_path)
        if mbox is not None:
            if str_prop(mbox, "status") != ["okay"]:
                errors.append(f"{mbox_path}: status must be okay")
            if "power-domains" not in mbox.props or "resets" not in mbox.props:
                errors.append(f"{mbox_path}: missing power-domains or resets")

    display = req("/soc/display-subsystem")
    if display is not None:
        iommus = cell_prop(display, "iommus")
        required_darts = [
            "/soc/iommu@289304000",
            "/soc/iommu@315304000",
            "/soc/iommu@48d304000",
            "/soc/iommu@50d304000",
        ]
        for dart_path in required_darts:
            dn = req(dart_path)
            if dn is not None:
                ph = cell_prop(dn, "phandle")
                if not ph or ph[0] not in iommus:
                    errors.append(f"/soc/display-subsystem: iommus missing {dart_path}")

    # Verify global remote-endpoint symmetry.
    remote_map: dict[str, int] = {}
    for p, node in by_path.items():
        if "remote-endpoint" in node.props:
            cells = cell_prop(node, "remote-endpoint")
            if len(cells) != 1:
                errors.append(f"{p}: remote-endpoint must have 1 cell")
            else:
                remote_map[p] = cells[0]

    for p, target_ph in remote_map.items():
        target = by_phandle.get(target_ph)
        if target is None:
            errors.append(f"{p}: dangling remote-endpoint phandle {hex(target_ph)}")
            continue
        back_ph = remote_map.get(target.path)
        back = by_phandle.get(back_ph) if back_ph is not None else None
        if back is None or back.path != p:
            errors.append(f"{p}: asymmetric remote-endpoint -> {target.path}")

    expected_typec_names = ["typec0", "typec1", "typec2", "typec3"]
    dcp_specs = [
        ("/soc/dcp@48dc00000", 3, [4, 4, 4, 4], "/clock-dispext2"),
        ("/soc/dcp@50dc00000", 4, [6, 6, 6, 6], "/clock-dispext3"),
    ]
    route_targets: dict[tuple[int, int], str] = {}
    for dcp_path, dcp_index, mux_indices, clk_path in dcp_specs:
        dcp = req(dcp_path)
        if dcp is None:
            continue
        if str_prop(dcp, "status") != ["disabled"]:
            errors.append(f"{dcp_path}: status must stay disabled for aura firmware gating")
        if str_prop(dcp, "apple,connector-type") != ["USB-C"]:
            errors.append(f"{dcp_path}: apple,connector-type must be USB-C")
        if cell_prop(dcp, "apple,dcp-index") != [dcp_index]:
            errors.append(f"{dcp_path}: apple,dcp-index must be <{dcp_index}>")
        if cell_prop(dcp, "apple,typec-mux-indices") != mux_indices:
            errors.append(f"{dcp_path}: apple,typec-mux-indices mismatch")
        if cell_prop(dcp, "apple,typec-dptx-phys") != [0, 1, 2, 3]:
            errors.append(f"{dcp_path}: apple,typec-dptx-phys must be <0 1 2 3>")
        if str_prop(dcp, "phy-names") != expected_typec_names:
            errors.append(f"{dcp_path}: phy-names must cover typec0..3")
        if str_prop(dcp, "mux-control-names") != expected_typec_names:
            errors.append(f"{dcp_path}: mux-control-names must cover typec0..3")
        clk = by_path.get(clk_path)
        if clk is not None:
            clk_ph = cell_prop(clk, "phandle")
            if cell_prop(dcp, "clocks") != clk_ph:
                errors.append(f"{dcp_path}: clocks must point to {clk_path}")
        for prop in ("apple,bw-scratch", "apple,iomfb-surfaces", "resets", "mboxes", "iommus"):
            if prop not in dcp.props:
                errors.append(f"{dcp_path}: missing {prop}")

        for idx in range(4):
            ep_path = f"{dcp_path}/typec-routes/route@{idx}/port/endpoint"
            route_path = f"{dcp_path}/typec-routes/route@{idx}"
            route = req(route_path)
            if route is not None:
                if cell_prop(route, "reg") != [idx]:
                    errors.append(f"{route_path}: reg must be <{idx}>")
                if "mode-switch" not in route.props:
                    errors.append(f"{route_path}: missing mode-switch")
            ep = req(ep_path)
            if ep is not None and ep.path in remote_map:
                target = by_phandle.get(remote_map[ep.path])
                if target is not None:
                    route_targets[(idx, dcp_index - 1)] = target.path

    # Check every rear USB-C port controller connector/ports/port@3 links endpoint@0/2/3.
    usb_pd_nodes = sorted(
        p for p in by_path if re.search(r"/usb-pd@[0-9a-f]+$", p)
    )
    if len(usb_pd_nodes) != 4:
        errors.append(f"expected 4 usb-pd controllers, found {len(usb_pd_nodes)}")
    seen_routes: set[int] = set()
    for pd_path in usb_pd_nodes:
        port3 = req(f"{pd_path}/connector/ports/port@3")
        if port3 is None:
            continue
        route_indices: dict[int, int] = {}
        for ep_reg, target_prefix in [
            (0, "/soc/dcp@315c00000/typec-routes/route@"),
            (2, "/soc/dcp@48dc00000/typec-routes/route@"),
            (3, "/soc/dcp@50dc00000/typec-routes/route@"),
        ]:
            ep = req(f"{pd_path}/connector/ports/port@3/endpoint@{ep_reg}")
            if ep is None:
                continue
            if cell_prop(ep, "reg") != [ep_reg]:
                errors.append(f"{ep.path}: reg must be <{ep_reg}>")
            tph = remote_map.get(ep.path)
            target = by_phandle.get(tph) if tph is not None else None
            if target is None or not target.path.startswith(target_prefix):
                errors.append(f"{ep.path}: must point to {target_prefix}*")
            else:
                m = re.search(r"/route@(\d+)/port/endpoint$", target.path)
                if not m:
                    errors.append(f"{ep.path}: unexpected target path {target.path}")
                else:
                    route_indices[ep_reg] = int(m.group(1))
        if len(route_indices) == 3:
            if len(set(route_indices.values())) != 1:
                errors.append(
                    f"{pd_path}/connector/ports/port@3: mismatched route indices across dcpext1/2/3: {route_indices}"
                )
            else:
                seen_routes.add(next(iter(route_indices.values())))
    if seen_routes != {0, 1, 2, 3}:
        errors.append(f"rear usb-pd controllers must cover routes {{0,1,2,3}}, got {sorted(seen_routes)}")

    return errors


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    errs = check_dtb(Path(argv[1]))
    if errs:
        for err in errs:
            print(err, file=sys.stderr)
        return 1
    print("j475c dcpext0-3 display topology ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
