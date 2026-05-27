#!/usr/bin/env python3

import argparse
import collections
import pathlib
import re
import sys


SEND_FLOW_RE = re.compile(
    r"\[Packet sending event\]\s+(\d+)SendFlow to\s+(\d+).*flow_id\s+(-?\d+)"
)
SEND_TICK_RE = re.compile(r"at the tick:\s+(\d+)")
FLOW_KEY_RE = re.compile(
    r"\[BarrierFlowKey\]\s+src\s+(\d+)\s+dst\s+(\d+)\s+layer\s+(\d+)\s+tag_id\s+(-?\d+)\s+flow_id\s+(-?\d+)\s+channel_id\s+(-?\d+)\s+chunk_id\s+(-?\d+)\s+group_mode\s+([A-Za-z0-9_+-]+)\s+group_id\s+(\d+)\s+size\s+(\d+)"
)
PASS_FINISH_RE = re.compile(r"pass:\s+(\d+)\s+finished at time:\s+(\d+)")
ALL_PASSES_RE = re.compile(r"all passes finished at time:\s+(\d+)")
STREAM_INJECTED_RE = re.compile(r"Total streams injected:\s+(\d+)")
STREAM_FINISHED_RE = re.compile(r"Total streams finished:\s+(\d+)")
ROUND_COMPLETE_RE = re.compile(
    r"simai-round-monitor\s+round_complete\s+tick=(\d+)\s+streams_finished=(\d+)\s+streams_injected=(\d+)"
)
BARRIER_RE = re.compile(
    r"barrier-tail-prio\s+(enable|disable)\s+node:(\d+)\s+group:(\d+)\s+src:(\d+)\s+dst:(\d+)\s+sport:(\d+)\s+pg:(\d+)"
)
BARRIER_TRIGGER_DIAG_RE = re.compile(
    r"barrier-tail-diag\s+trigger\s+node:(\d+)\s+group:(\d+)\s+src:(\d+)\s+dst:(\d+)\s+sport:(\d+)\s+"
    r"bytes_left:(\d+)\s+active_sources:(\d+)\s+completed_sources:(\d+)\s+on_the_fly:(\d+)\s+base_pg:(\d+)\s+boost_pg:(\d+)"
)
LOCAL_SELECT_DIAG_RE = re.compile(
    r"barrier-tail-diag\s+local-select\s+src:(\d+)\s+dst:(\d+)\s+sport:(\d+)\s+pg:(\d+)\s+"
    r"bytes_left:(\d+)\s+competing_sendable:(\d+)\s+rr_last:(\d+)"
)
SWITCH_ENQUEUE_DIAG_RE = re.compile(
    r"barrier-tail-diag\s+switch-enqueue\s+switch:(\d+)\s+in:(\d+)\s+out:(\d+)\s+q:(\d+)\s+"
    r"src:(\d+)\s+dst:(\d+)\s+size:(\d+)\s+egress_pg1:(\d+)\s+egress_pg3:(\d+)\s+egress_total:(\d+)"
)
RETAIN_BLOCK_DIAG_RE = re.compile(
    r"barrier-tail-diag\s+retain-block\s+src:(\d+)\s+dst:(\d+)\s+sport:(\d+)\s+"
    r"bytes_left:(\d+)\s+on_the_fly:(\d+)\s+cap:(\d+)"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Summarize SimAI ns-3 experiment logs for barrier-tail-priority "
            "validation and fan-in structure checks."
        )
    )
    parser.add_argument(
        "--simai-log",
        required=True,
        help="Path to SimAI.log containing '[Packet sending event]' lines.",
    )
    parser.add_argument(
        "--stdout-log",
        required=True,
        help="Path to simulator stdout/stderr capture.",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Maximum number of fan-in groups to print when fan-in > 1 exists.",
    )
    return parser.parse_args()


def read_lines(path: pathlib.Path):
    try:
        with path.open("r", errors="ignore") as f:
            for line in f:
                yield line.rstrip("\n")
    except FileNotFoundError:
        print(f"missing file: {path}", file=sys.stderr)
        sys.exit(1)


def mix_group_field(seed: int, value: int) -> int:
    return seed ^ (value + 0x9E3779B97F4A7C15 + ((seed << 6) & ((1 << 64) - 1)) + (seed >> 2))


def hash_group_fields(*values: int) -> int:
    seed = 0xCBF29CE484222325
    for value in values:
        seed = mix_group_field(seed, value & 0xFFFFFFFF)
        seed &= (1 << 64) - 1
    return seed


def summarize_groups(
    groups: dict[tuple[object, ...], set[int]],
) -> tuple[int, int, list[tuple[int, tuple[object, ...], list[int]]]]:
    fanin_groups: list[tuple[int, tuple[object, ...], list[int]]] = []
    max_fanin = 0
    for group_key, srcs in groups.items():
        fanin = len(srcs)
        max_fanin = max(max_fanin, fanin)
        if fanin > 1:
            fanin_groups.append((fanin, group_key, sorted(srcs)))
    fanin_groups.sort(key=lambda item: (-item[0], item[1]))
    return len(groups), max_fanin, fanin_groups


def format_group_key(group_key: tuple[object, ...]) -> str:
    dst = group_key[0]
    rest = group_key[1:]
    if len(rest) == 1:
        return f"dst={dst} key={rest[0]}"
    return f"dst={dst} key={rest}"


def format_int_summary(values: list[int]) -> str:
    if not values:
        return "none"
    return f"count={len(values)} min={min(values)} max={max(values)}"


def format_counter(counter: collections.Counter[int]) -> str:
    if not counter:
        return "none"
    return ", ".join(f"{key}:{counter[key]}" for key in sorted(counter))


def min_max_summary(count: int, min_val: int | None, max_val: int | None) -> str:
    if count == 0 or min_val is None or max_val is None:
        return "none"
    return f"count={count} min={min_val} max={max_val}"


def update_min_max(count: int, min_val: int | None, max_val: int | None, value: int):
    if count == 0:
        return 1, value, value
    assert min_val is not None and max_val is not None
    if value < min_val:
        min_val = value
    if value > max_val:
        max_val = value
    return count + 1, min_val, max_val


def main() -> int:
    args = parse_args()
    simai_log = pathlib.Path(args.simai_log)
    stdout_log = pathlib.Path(args.stdout_log)

    dst_flow_to_srcs: dict[tuple[int, int], set[int]] = collections.defaultdict(set)
    candidate_groups: dict[str, dict[tuple[object, ...], set[int]]] = (
        collections.defaultdict(lambda: collections.defaultdict(set))
    )
    sendflow_lines = 0
    max_send_tick: int | None = None
    flow_key_lines = 0
    configured_group_modes: set[str] = set()
    for line in read_lines(simai_log):
        flow_key_match = FLOW_KEY_RE.search(line)
        if flow_key_match:
            (
                src_s,
                dst_s,
                layer_s,
                tag_id_s,
                flow_id_s,
                channel_id_s,
                chunk_id_s,
                group_mode,
                group_id_s,
                _size_s,
            ) = flow_key_match.groups()
            src = int(src_s)
            dst = int(dst_s)
            layer = int(layer_s)
            tag_id = int(tag_id_s)
            flow_id = int(flow_id_s)
            channel_id = int(channel_id_s)
            chunk_id = int(chunk_id_s)
            group_id = int(group_id_s)
            flow_key_lines += 1
            sendflow_lines += 1
            configured_group_modes.add(group_mode)

            candidate_groups["flow_id"][(dst, flow_id)].add(src)
            candidate_groups["tag_id"][(dst, tag_id)].add(src)
            candidate_groups["channel_id"][(dst, channel_id)].add(src)
            candidate_groups["channel_chunk"][(dst, channel_id, chunk_id)].add(src)
            candidate_groups["layer_channel_chunk"][
                (dst, layer, channel_id, chunk_id)
            ].add(src)
            candidate_groups["hashed_channel_chunk"][
                (dst, hash_group_fields(channel_id, chunk_id))
            ].add(src)
            candidate_groups["hashed_layer_channel_chunk"][
                (dst, hash_group_fields(layer, channel_id, chunk_id))
            ].add(src)
            candidate_groups[f"configured:{group_mode}"][(dst, group_id)].add(src)
            tick_match = SEND_TICK_RE.search(line)
            if tick_match:
                tick_val = int(tick_match.group(1))
                if max_send_tick is None or tick_val > max_send_tick:
                    max_send_tick = tick_val
            continue
        match = SEND_FLOW_RE.search(line)
        if not match:
            continue
        src, dst, flow_id = map(int, match.groups())
        dst_flow_to_srcs[(dst, flow_id)].add(src)
        sendflow_lines += 1
        tick_match = SEND_TICK_RE.search(line)
        if tick_match:
            tick_val = int(tick_match.group(1))
            if max_send_tick is None or tick_val > max_send_tick:
                max_send_tick = tick_val

    if flow_key_lines == 0:
        candidate_groups["flow_id"] = dst_flow_to_srcs

    barrier_events: list[dict[str, int | str]] = []
    pass_finished: list[tuple[int, int]] = []
    all_passes_finished: list[int] = []
    streams_injected: list[int] = []
    streams_finished: list[int] = []
    round_complete_markers: list[tuple[int, int, int]] = []
    trigger_events = 0
    trigger_bytes_count = 0
    trigger_bytes_min: int | None = None
    trigger_bytes_max: int | None = None
    trigger_active_counter: collections.Counter[int] = collections.Counter()
    trigger_on_the_fly_count = 0
    trigger_on_the_fly_min: int | None = None
    trigger_on_the_fly_max: int | None = None
    local_select_events = 0
    local_competing_count = 0
    local_competing_min: int | None = None
    local_competing_max: int | None = None
    switch_enqueue_events = 0
    switch_pg1_count = 0
    switch_pg1_min: int | None = None
    switch_pg1_max: int | None = None
    switch_pg3_count = 0
    switch_pg3_min: int | None = None
    switch_pg3_max: int | None = None
    retain_block_events = 0
    retain_bytes_count = 0
    retain_bytes_min: int | None = None
    retain_bytes_max: int | None = None
    retain_on_the_fly_count = 0
    retain_on_the_fly_min: int | None = None
    retain_on_the_fly_max: int | None = None
    retain_caps: collections.Counter[int] = collections.Counter()
    segfault = False

    for line in read_lines(stdout_log):
        match = BARRIER_RE.search(line)
        if match:
            action, node, group, src, dst, sport, pg = match.groups()
            barrier_events.append(
                {
                    "action": action,
                    "node": int(node),
                    "group": int(group),
                    "src": int(src),
                    "dst": int(dst),
                    "sport": int(sport),
                    "pg": int(pg),
                }
            )
        match = BARRIER_TRIGGER_DIAG_RE.search(line)
        if match:
            (
                _node,
                _group,
                _src,
                _dst,
                _sport,
                bytes_left,
                active_sources,
                _completed_sources,
                on_the_fly,
                _base_pg,
                _boost_pg,
            ) = map(int, match.groups())
            trigger_events += 1
            trigger_bytes_count, trigger_bytes_min, trigger_bytes_max = update_min_max(
                trigger_bytes_count, trigger_bytes_min, trigger_bytes_max, bytes_left
            )
            trigger_active_counter[active_sources] += 1
            (
                trigger_on_the_fly_count,
                trigger_on_the_fly_min,
                trigger_on_the_fly_max,
            ) = update_min_max(
                trigger_on_the_fly_count,
                trigger_on_the_fly_min,
                trigger_on_the_fly_max,
                on_the_fly,
            )
        match = LOCAL_SELECT_DIAG_RE.search(line)
        if match:
            (
                _src,
                _dst,
                _sport,
                _pg,
                _bytes_left,
                competing_sendable,
                _rr_last,
            ) = map(int, match.groups())
            local_select_events += 1
            (
                local_competing_count,
                local_competing_min,
                local_competing_max,
            ) = update_min_max(
                local_competing_count,
                local_competing_min,
                local_competing_max,
                competing_sendable,
            )
        match = SWITCH_ENQUEUE_DIAG_RE.search(line)
        if match:
            (
                _switch,
                _in_dev,
                _out_dev,
                _q_index,
                _src,
                _dst,
                _size,
                egress_pg1,
                egress_pg3,
                _egress_total,
            ) = map(int, match.groups())
            switch_enqueue_events += 1
            switch_pg1_count, switch_pg1_min, switch_pg1_max = update_min_max(
                switch_pg1_count, switch_pg1_min, switch_pg1_max, egress_pg1
            )
            switch_pg3_count, switch_pg3_min, switch_pg3_max = update_min_max(
                switch_pg3_count, switch_pg3_min, switch_pg3_max, egress_pg3
            )
        match = RETAIN_BLOCK_DIAG_RE.search(line)
        if match:
            _src, _dst, _sport, bytes_left, on_the_fly, cap = map(int, match.groups())
            retain_block_events += 1
            retain_bytes_count, retain_bytes_min, retain_bytes_max = update_min_max(
                retain_bytes_count, retain_bytes_min, retain_bytes_max, bytes_left
            )
            (
                retain_on_the_fly_count,
                retain_on_the_fly_min,
                retain_on_the_fly_max,
            ) = update_min_max(
                retain_on_the_fly_count,
                retain_on_the_fly_min,
                retain_on_the_fly_max,
                on_the_fly,
            )
            retain_caps[cap] += 1
        match = PASS_FINISH_RE.search(line)
        if match:
            pass_finished.append((int(match.group(1)), int(match.group(2))))
        match = ALL_PASSES_RE.search(line)
        if match:
            all_passes_finished.append(int(match.group(1)))
        match = STREAM_INJECTED_RE.search(line)
        if match:
            streams_injected.append(int(match.group(1)))
        match = STREAM_FINISHED_RE.search(line)
        if match:
            streams_finished.append(int(match.group(1)))
        match = ROUND_COMPLETE_RE.search(line)
        if match:
            round_complete_markers.append(
                (int(match.group(1)), int(match.group(2)), int(match.group(3)))
            )
        if "Segmentation fault" in line:
            segfault = True

    candidate_summaries: dict[str, dict[str, object]] = {}
    for candidate_name, groups in candidate_groups.items():
        unique_groups, max_fanin, fanin_groups = summarize_groups(groups)
        candidate_summaries[candidate_name] = {
            "unique_groups": unique_groups,
            "max_fanin": max_fanin,
            "fanin_groups": fanin_groups,
        }

    flow_summary = candidate_summaries.get(
        "flow_id",
        {"unique_groups": 0, "max_fanin": 0, "fanin_groups": []},
    )
    max_fanin = int(flow_summary["max_fanin"])
    fanin_groups = flow_summary["fanin_groups"]

    barrier_enable = sum(1 for event in barrier_events if event["action"] == "enable")
    barrier_disable = sum(
        1 for event in barrier_events if event["action"] == "disable"
    )

    print(f"stdout_log: {stdout_log}")
    print(f"simai_log: {simai_log}")
    print(f"segmentation_fault: {'yes' if segfault else 'no'}")
    print(
        "group_key_source: "
        + ("BarrierFlowKey" if flow_key_lines > 0 else "PacketSendingEvent(flow_id only)")
    )
    print(f"sendflow_lines: {sendflow_lines}")
    print(f"barrier_flow_key_lines: {flow_key_lines}")
    print(f"max_send_tick: {max_send_tick if max_send_tick is not None else 'unknown'}")
    if configured_group_modes:
        print(f"configured_group_modes: {sorted(configured_group_modes)}")
    print(f"unique_dst_flow_groups: {flow_summary['unique_groups']}")
    print(f"max_fanin_per_(dst,flow_id): {max_fanin}")
    print(f"groups_with_fanin_gt_1: {len(fanin_groups)}")
    print(f"barrier_tail_prio_enable: {barrier_enable}")
    print(f"barrier_tail_prio_disable: {barrier_disable}")
    print(f"barrier_tail_prio_total: {len(barrier_events)}")
    print(f"pass_finished: {pass_finished if pass_finished else 'none'}")
    print(
        "all_passes_finished: "
        f"{all_passes_finished if all_passes_finished else 'none'}"
    )
    print(
        f"total_streams_injected: {streams_injected[-1] if streams_injected else 'unknown'}"
    )
    print(
        f"total_streams_finished: {streams_finished[-1] if streams_finished else 'unknown'}"
    )
    print(
        "round_complete_markers: "
        f"{round_complete_markers if round_complete_markers else 'none'}"
    )

    print("\nBarrier-tail diagnostic summary:")
    print(f"  trigger_events: {trigger_events}")
    print(
        f"  trigger_bytes_left: "
        f"{min_max_summary(trigger_bytes_count, trigger_bytes_min, trigger_bytes_max)}"
    )
    print(f"  trigger_active_sources: {format_counter(trigger_active_counter)}")
    print(
        f"  trigger_on_the_fly: "
        f"{min_max_summary(trigger_on_the_fly_count, trigger_on_the_fly_min, trigger_on_the_fly_max)}"
    )
    print(f"  local_select_events: {local_select_events}")
    print(
        f"  local_competing_sendable: "
        f"{min_max_summary(local_competing_count, local_competing_min, local_competing_max)}"
    )
    print(f"  switch_enqueue_events: {switch_enqueue_events}")
    print(
        f"  switch_egress_pg1_bytes: "
        f"{min_max_summary(switch_pg1_count, switch_pg1_min, switch_pg1_max)}"
    )
    print(
        f"  switch_egress_pg3_bytes: "
        f"{min_max_summary(switch_pg3_count, switch_pg3_min, switch_pg3_max)}"
    )
    print(f"  retain_block_events: {retain_block_events}")
    print(
        f"  retain_block_bytes_left: "
        f"{min_max_summary(retain_bytes_count, retain_bytes_min, retain_bytes_max)}"
    )
    print(
        f"  retain_block_on_the_fly: "
        f"{min_max_summary(retain_on_the_fly_count, retain_on_the_fly_min, retain_on_the_fly_max)}"
    )
    print(f"  retain_block_caps: {format_counter(retain_caps)}")

    print("\nCandidate fan-in summary:")
    preferred_order = [
        "flow_id",
        "tag_id",
        "channel_id",
        "channel_chunk",
        "layer_channel_chunk",
        "hashed_channel_chunk",
        "hashed_layer_channel_chunk",
    ]
    ordered_candidates = [
        name for name in preferred_order if name in candidate_summaries
    ] + sorted(
        name
        for name in candidate_summaries
        if name not in preferred_order
    )
    for candidate_name in ordered_candidates:
        summary = candidate_summaries[candidate_name]
        print(
            f"  {candidate_name}: unique_groups={summary['unique_groups']} "
            f"max_fanin={summary['max_fanin']} "
            f"groups_with_fanin_gt_1={len(summary['fanin_groups'])}"
        )

    printed_any_top = False
    for candidate_name in ordered_candidates:
        summary = candidate_summaries[candidate_name]
        if not summary["fanin_groups"]:
            continue
        printed_any_top = True
        print(f"\nTop fan-in groups for {candidate_name}:")
        for fanin, group_key, srcs in summary["fanin_groups"][: args.top]:
            print(f"  {format_group_key(group_key)} fanin={fanin} srcs={srcs}")
    if not printed_any_top:
        print("\nNo candidate grouping produced fan-in > 1.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
