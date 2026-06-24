# Closed-loop Resource Allocation Demo

This demo focuses only on closed-loop resource allocation:

```text
measure -> decide -> apply -> verify
```

It does not implement two-path path computation.

## Run Order

Run these commands inside the Ubuntu VM:

```bash
cd ~/5g-lab

docker compose --profile monitoring up -d prometheus pushgateway grafana

bash scripts/demo-sla-violation.sh
```

Open Grafana:

```text
http://localhost:3000/d/5g-network-slicing-demo/5g-network-slicing-resource-optimization-demo
```

Default login is usually:

```text
admin / admin
```

## What The Demo Does

1. Resets old Pushgateway metrics for the `slice-controller` job.
2. Applies `no-policy` and measures baseline eMBB throughput.
3. Applies `dynamic-normal` and measures eMBB throughput plus URLLC latency.
4. Applies `fault-urllc-congestion` to create URLLC SLA pressure.
5. Runs the controller once.
6. The controller should select `dynamic-urllc-priority`.
7. Measures eMBB throughput again under the priority policy.
8. Runs the controller a few more iterations so hysteresis can return to `dynamic-normal`.
9. Writes:

```text
reports/closed-loop-results.csv
reports/closed-loop-summary.md
```

## Grafana Panels

- Current Policy: active controller policy from `slice_policy_active == 1`.
- eMBB Allocated Mbps: current eMBB resource budget from `current_embb_allocated_mbps`.
- URLLC Allocated Mbps: current URLLC resource budget from `current_urllc_allocated_mbps`.
- URLLC SLA Status: `OK` or `VIOLATION` from `current_sla_violation`.
- Testbed Note: reminds reviewers that tc/htb/netem/fq_codel is only a testbed proxy.
- URLLC Latency ms: RTT latency measured through `uesimtun0`, plus the 15 ms SLA threshold line.
- eMBB Throughput Mbps: throughput parsed from `scripts/test-embb.sh` and pushed as `current_embb_throughput_mbps`.
- URLLC Packet Loss %: packet loss parsed from ping output as `current_urllc_loss_percent`.
- Allocated Bandwidth History: current eMBB and URLLC resource budgets over time.

Expected story:

- Normal state: `dynamic-normal`, eMBB 12 Mbps, URLLC 3 Mbps.
- Fault state: URLLC latency rises because `fault-urllc-congestion` adds delay/loss.
- Controller response: policy changes to `dynamic-urllc-priority`, eMBB 10 Mbps, URLLC 5 Mbps.
- Recovery: URLLC latency returns lower, then hysteresis can move back to `dynamic-normal`.

## Scope Note

tc/htb/netem/fq_codel is only a testbed proxy for resource pressure and policy enforcement, not standard 5G QoS.
