# Small MoE Experiment

This directory contains a minimal MoE-like experiment for evaluating barrier-tail priority boosting.

## Scenario

- 8 GPUs on the official `Spectrum-X_8g_8gps_400Gbps_H100` topology
- MoE-like repeated `ALLTOALL_EP` communication
- One optional straggler sender, created by degrading a single 400 Gbps GPU-to-switch link to 100 Gbps

The original hand-written `1 ToR / 1 GPU per server` topology is kept for reference, but the runnable experiment uses the official Spectrum-X 8 GPU topology because AstraSim's `MockNcclGroup` initialization expects the NVSwitch mapping carried by that format.

## Files

- `moe_ep8_incast.txt`: minimal MoE-like workload with repeated `ALLTOALL_EP` phases
- `SimAI.moe-small.conf`: writable simulator config for this experiment
- `topo_spectrumx_8g_8gps_400g_straggler.txt`: Spectrum-X variant with one slowed sender link
- `run_experiment.sh`: runner for uniform and straggler comparisons

## Main Comparison

- `uniform_baseline`: uniform topology, `SIMAI_ENABLE_BARRIER_TAIL_PRIO=0`
- `uniform_proposed`: uniform topology, `SIMAI_ENABLE_BARRIER_TAIL_PRIO=1`
- `straggler_baseline`: straggler topology, `SIMAI_ENABLE_BARRIER_TAIL_PRIO=0`
- `straggler_proposed`: straggler topology, `SIMAI_ENABLE_BARRIER_TAIL_PRIO=1`

Each run emits:

- `*.stdout.log`: full simulator stdout
- `*.fct.txt`: per-flow completion data for that case
- `*.summary.txt`: iteration finish time, priority event counts, and flow-level summary metrics

## Suggested First Run

```bash
cd /path/to/simai-moe-barrier-priority
bash experiments/moe_small/run_experiment.sh
```
