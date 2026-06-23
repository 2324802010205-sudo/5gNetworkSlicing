# 5G Network Slicing Lab

Docker Compose lab for Open5GS 2.7.5 + UERANSIM 3.2.6 with two research slices:

- eMBB: UE `ue-embb`, DNN `internet`, S-NSSAI `SST=1, SD=000001`, subnet `10.45.0.0/16`.
- URLLC: UE `ue-urllc`, DNN `internet2`, S-NSSAI `SST=2, SD=000002`, subnet `10.46.0.0/16`.

The goal is not only to draw nice Grafana charts. The lab is shaped to prove resource optimization behavior: when eMBB creates heavy broadband load, URLLC should keep latency/loss inside SLA after static or dynamic allocation is applied.

## What Is Real 5G Slicing In This Lab?

The real slicing part of this lab is the control-plane and user-plane separation that Open5GS can represent locally:

- eMBB UE requests S-NSSAI `SST=1, SD=000001` with DNN `internet`.
- URLLC UE requests S-NSSAI `SST=2, SD=000002` with DNN `internet2`.
- AMF advertises both supported S-NSSAI values.
- SMF maps the DNN/S-NSSAI sessions to the intended UPFs.
- `upf-embb` and `upf-urllc` are isolated user-plane functions with separate UE subnets and tunnel gateways.

In this lab, a slice is considered correctly demonstrated only when the UE obtains the intended `uesimtun0` address, the route used by the traffic goes through `uesimtun0`, and packets are observed on the expected UPF.

## What Is Testbed Emulation/Proxy?

The Linux `tc`, `netem`, HTB, and `fq_codel` policies in this project are testbed shaping tools. They emulate resource pressure, queueing behavior, and latency/loss effects so the experiment can compare policies on a small VM.

They are not native 3GPP QoS enforcement through PFCP QER. Do not interpret the lab as proving that network slicing automatically creates low latency for URLLC. Low latency in this setup comes from the selected testbed policy, shaping, and allocator behavior.

## Refactor Summary

This project was refactored to run lighter on Ubuntu VM/MacBook Air M1 and to better support the eMBB + URLLC research goal.

Main changes:

- Docker Compose now uses profiles: `core`, `monitoring`, `heavy-monitoring`, `traffic`, and `webui`.
- `.env` makes `core` the default profile, so `docker compose up -d` no longer starts Prometheus, Grafana, cAdvisor, or node-exporter by default.
- Restart policy is controlled by `RESTART_POLICY` and defaults to `on-failure:3` for easier debugging.
- Monitoring images are pinned instead of using `latest`.
- Grafana plugin auto-install was removed to reduce startup time and network dependency.
- Prometheus scrape/evaluation interval was raised from `5s` to `15s`.
- Grafana dashboard refresh was raised from `5s` to `15s`.
- NSSF was added with two configured slices: eMBB `SST=1, SD=000001` and URLLC `SST=2, SD=000002`.
- AMF was configured to use NRF and NSSF while SMF still maps DNN/S-NSSAI to the two UPFs.
- Pushgateway custom UPF metrics were aligned with Prometheus job labels `upf-embb` and `upf-urllc`.
- Traffic scripts were added for eMBB TCP, URLLC UDP small packets, and mixed contention.
- A SLA-aware dynamic allocator was added using Linux `tc` HTB + `fq_codel`, not Deep Reinforcement Learning.
- `check-5g.sh` was rewritten to focus on core health and treat monitoring/traffic services as optional.
- `ALL_CONFIGS_FULL.md` was regenerated so the combined config snapshot matches the refactored project.

Important files added or changed:

- `.env`: default profiles and restart policy.
- `docker-compose.yaml`: profile-based lightweight service layout.
- `config/nssf.yaml`: NSSF configuration for two slices.
- `config/amf.yaml`: AMF client configuration for NSSF.
- `config/prometheus.yml`: lighter scrape settings and consistent jobs.
- `scripts/push-metrics.sh`: custom UPF byte counters through Pushgateway.
- `scripts/test-embb.sh`: eMBB TCP throughput test.
- `scripts/test-urllc.sh`: URLLC UDP small-packet test.
- `scripts/test-mixed.sh`: simultaneous eMBB load and URLLC test.
- `scripts/controller/sla_dynamic_allocator.py`: dynamic SLA-aware resource allocator.
- `check-5g.sh`: PASS/WARN/FAIL health check.
- `README.md`: updated runbook and research explanation.

## Components

- UE: simulated user device from UERANSIM. `ue-embb` models video/cloud traffic; `ue-urllc` models robot/sensor traffic.
- gNB: simulated 5G base station that connects both UEs to the AMF.
- AMF: handles registration, mobility, and access control. It is configured with both S-NSSAI values.
- NSSF: slice selection function. This project includes `config/nssf.yaml` with both eMBB and URLLC slices and registers it through NRF.
- SMF: maps sessions to UPF by DNN/S-NSSAI: `internet` to `upf-embb`, `internet2` to `upf-urllc`.
- UPF: user-plane forwarding. `upf-embb` owns `10.45.0.1/16`; `upf-urllc` owns `10.46.0.1/16`.
- MongoDB: stores Open5GS subscriber/configuration data. It does not carry or store video/robot traffic.
- Prometheus/Grafana: optional monitoring profile. Keep it off while debugging core registration on a small VM.

If NSSF causes Open5GS compatibility issues in your environment, you can temporarily remove `nssf` from the AMF dependency/client and keep the current DNN/S-NSSAI-to-SMF/UPF model. In that fallback, document the result as slicing by SMF+UPF policy, not a full NSSF-driven deployment.

## Lightweight Profiles

`.env` sets:

```bash
COMPOSE_PROFILES=core
RESTART_POLICY=on-failure:3
```

So the default command starts only the lightweight core:

```bash
docker compose up -d
```

Optional profiles:

```bash
docker compose --profile monitoring up -d prometheus grafana pushgateway
docker compose --profile heavy-monitoring up -d node-exporter cadvisor
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server mqtt-server
docker compose --profile webui up -d webui
```

When the setup is stable, change `.env` to:

```bash
RESTART_POLICY=unless-stopped
```

## Ubuntu VM 5GB Mode

Recommended VM resources:

- RAM: 5GB.
- CPU: 2 cores.
- Ubuntu swap: 4GB.

The default `.env` keeps the lab in `core` profile only. This is the intended mode for Phase 1 debugging: verify core, verify UE registration, verify routes, and verify slice path. Do not enable `monitoring`, `heavy-monitoring`, `webui`, or `traffic` while debugging Phase 1 unless you need that specific component.

Run the lightweight core:

```bash
docker compose down
docker compose up -d
```

Check host/container pressure:

```bash
docker ps
free -h
docker stats
bash ./check-5g.sh
```

Only start traffic servers when running tests:

```bash
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server
```

Stop optional traffic services after testing:

```bash
docker compose stop embb-iperf-server urllc-iperf-server mqtt-server
```

Or stop all optional/heavy services:

```bash
bash scripts/stop-heavy.sh
```

## Health Check

```bash
bash ./check-5g.sh
```

It checks Docker, Compose syntax, Mongo health, core containers, AMF/gNB/UE registration clues, PDU/PFCP activity, UE `uesimtun0`, slice gateway ping, and UPF `tc` policy. Optional monitoring/traffic services are WARN only.

Useful manual checks:

```bash
docker compose ps
docker logs amf --tail 80
docker logs smf --tail 80
docker logs nssf --tail 80
docker exec ue-embb ip addr show uesimtun0
docker exec ue-urllc ip addr show uesimtun0
docker exec upf-embb tc qdisc show dev ogstun
docker exec upf-urllc tc qdisc show dev ogstun
```

## Traffic Tests

Start traffic services:

```bash
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server
```

Run eMBB TCP throughput:

```bash
bash scripts/test-embb.sh
```

This runs a reverse TCP test with `iperf3 -R`, `-P 2` by default, binds to the eMBB `uesimtun0` IP, checks `ip route get`, and writes `reports/embb-test-<timestamp>.log`. Use higher parallelism only as an explicit stress test.

Run URLLC UDP small packets:

```bash
bash scripts/test-urllc.sh
```

This runs UDP at 200 Kbps with 128-byte packets for 60 seconds by default, binds to the URLLC `uesimtun0` IP, checks `ip route get`, runs `ping -I uesimtun0`, prints jitter/loss output, and writes `reports/urllc-test-<timestamp>.log`.

Run mixed contention:

```bash
bash scripts/test-mixed.sh
```

The eMBB flow represents 4K/8K video, cloud gaming, or large download pressure. The URLLC flow represents robot/camera/sensor control messages: smaller packets, lower bitrate, stricter latency/loss target.

Verify that traffic is on the intended slice path:

```bash
bash scripts/verify-slice-path.sh
```

The path verification writes `reports/slice-path-verification.txt` and checks:

- eMBB packets are observed on `upf-embb`.
- URLLC packets are observed on `upf-urllc`.
- eMBB is not observed on `upf-urllc`.
- URLLC is not observed on `upf-embb`.

Verify NSSF presence and log evidence:

```bash
bash scripts/verify-nssf.sh
```

If the script cannot confirm runtime AMF-to-NSSF network slice selection from logs, it reports that NSSF is present but the current slicing may still rely on static AMF/SMF configuration.

## Monitoring

Monitoring is optional because it is expensive on Ubuntu VM/MacBook Air M1. Prometheus now scrapes every 15 seconds, and Grafana dashboards refresh every 15 seconds.

```bash
docker compose --profile monitoring up -d prometheus grafana pushgateway
nohup bash scripts/push-metrics.sh > /tmp/push-metrics.log 2>&1 &
```

Open:

- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000

Grafana login: `admin` / `admin`.

The custom UPF byte counters are pushed with job labels:

```promql
rate(upf_embb_rx_bytes_total{job="upf-embb"}[30s]) * 8 / 1000000
rate(upf_embb_tx_bytes_total{job="upf-embb"}[30s]) * 8 / 1000000
rate(upf_urllc_rx_bytes_total{job="upf-urllc"}[30s]) * 8 / 1000000
rate(upf_urllc_tx_bytes_total{job="upf-urllc"}[30s]) * 8 / 1000000
```

Check available metric names:

```bash
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep -E 'upf|fivegs'
curl -s http://localhost:9091/metrics | grep -E 'upf_.*bytes'
```

If old underscore jobs remain in Pushgateway:

```bash
curl -X DELETE http://localhost:9091/metrics/job/upf_embb
curl -X DELETE http://localhost:9091/metrics/job/upf_urllc
curl -X DELETE http://localhost:9091/metrics/job/upf-embb
curl -X DELETE http://localhost:9091/metrics/job/upf-urllc
```

## Resource Optimization

The simple baseline bottleneck is applied with Linux `tc` on each UPF `ogstun`. This is not a perfect shared radio scheduler, but it creates measurable resource pressure that is suitable for a VM-first experiment.

Apply static QoS:

```bash
bash ./fix-upf.sh
```

Run the SLA-aware dynamic allocator:

```bash
python3 scripts/controller/sla_dynamic_allocator.py --mode dynamic_sla_slicing --duration 120
```

Available modes:

```bash
python3 scripts/controller/sla_dynamic_allocator.py --mode no_slicing_baseline --duration 60
python3 scripts/controller/sla_dynamic_allocator.py --mode static_slicing --duration 60
python3 scripts/controller/sla_dynamic_allocator.py --mode dynamic_sla_slicing --duration 120
```

The controller samples every 3 seconds by default and writes CSV:

```text
timestamp,mode,embb_mbps,urllc_latency_ms,urllc_loss_percent,urllc_bw_limit,embb_bw_limit
```

Policy:

- If URLLC latency exceeds 20 ms or loss exceeds 0.1%, increase URLLC bandwidth/priority and reduce eMBB.
- If URLLC stays healthy for 3 cycles, reduce URLLC to its minimum and give spare capacity back to eMBB.
- The implementation uses Linux `tc` HTB + `fq_codel`, not Deep Reinforcement Learning.

## Evaluation Criteria

Use these metrics in the report:

- eMBB throughput, Mbps.
- URLLC latency, average or p95.
- URLLC jitter.
- URLLC packet loss.
- SLA violation rate.
- Resource utilization and allocation efficiency.

The expected story is:

1. `no_slicing_baseline`: eMBB load can disturb URLLC.
2. `static_slicing`: URLLC is protected, but capacity may be less flexible.
3. `dynamic_sla_slicing`: URLLC receives more resources during SLA risk, then eMBB gets bandwidth back when URLLC is stable.

## Cleanup

```bash
docker compose down
```

Remove generated data:

```bash
docker compose down -v
sudo rm -rf mongodb_data prometheus_data grafana_data reports
```
