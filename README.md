# 5G Network Slicing Lab

Open5GS + UERANSIM + Docker Compose lab for two slices:

- eMBB: SST 1, SD 000001, DNN `internet`, subnet `10.45.0.0/16`
- uRLLC: SST 2, SD 000002, DNN `internet2`, subnet `10.46.0.0/16`

## Requirements

- Ubuntu 22.04 or WSL2 with Linux containers
- Docker and Docker Compose
- At least 8 GB RAM and 4 CPU cores
- Host IP forwarding/NAT enabled if UEs need internet access

## Start

```bash
docker compose up -d
```

The main compose file starts the 5G core, two UPFs, gNB, two UEs, Prometheus, Grafana, Pushgateway, Node Exporter, cAdvisor, and an iperf3 server for report-grade traffic generation.

## Fix UPF NAT/QoS

Run this after containers are up, or after restarting UPF/UE containers:

```bash
bash ./fix-upf.sh
```

The script keeps UPF gateway IPs aligned with `config/smf.yaml`:

- `upf-embb`: `10.45.0.1/16`
- `upf-urllc`: `10.46.0.1/16`

It also applies scaled slice resource profiles. The scale is intentional: this VM-based Open5GS UPF has a much lower data-plane ceiling than a hardware-accelerated 5G UPF, so the benchmark evaluates resource isolation and SLA behavior at the capacity the lab can actually forward.

- eMBB: 16 Mbps guaranteed rate, 20 Mbps ceiling, broadband-oriented queue.
- uRLLC: 4 Mbps guaranteed rate, 8 Mbps ceiling, low delay/jitter and `fq_codel` short queue.

## Check If The Lab Is OK

```bash
bash ./check-5g.sh
```

On Windows PowerShell:

```powershell
.\check-5g.ps1
```

This checks:

- Docker Compose syntax
- Required containers are running
- `uesimtun0` exists on both UEs
- Ping through each 5G tunnel
- QoS rules on both UPFs
- Prometheus readiness

Useful manual checks:

```bash
docker compose ps
docker logs amf --tail 50
docker logs smf --tail 50
docker logs upf-embb --tail 50
docker logs upf-urllc --tail 50
docker exec ue-embb ping -I uesimtun0 1.1.1.1 -c 4
docker exec ue-urllc ping -I uesimtun0 1.1.1.1 -c 4
docker exec upf-embb tc qdisc show dev ogstun
docker exec upf-urllc tc qdisc show dev ogstun
```

## Mongo Unhealthy

If `docker compose up -d` says `container mongo is unhealthy`, check the real reason first:

```bash
docker compose ps mongo
docker logs mongo --tail 100
docker inspect mongo --format '{{json .State.Health}}'
```

Common fixes:

```bash
docker compose restart mongo
sudo chown -R 999:999 mongodb_data
docker compose up -d
```

If this is a fresh lab and you do not need old subscriber data:

```bash
docker compose down
sudo rm -rf mongodb_data
docker compose up -d
```

## cAdvisor Port 8080 Busy

If Docker says `failed to bind host port ... 0.0.0.0:8080 ... address already in use`, another process is already using port `8080` on the VM. This lab does not need to expose cAdvisor on the host because Prometheus reaches it inside Docker at `cadvisor:8080`.

Check who uses the port:

```bash
sudo ss -ltnp | grep ':8080'
```

## Run The Resource Optimization Benchmark

Use this benchmark for report-ready numbers. It tests the topic of the project directly: per-slice resource allocation, uRLLC SLA protection, and stability under eMBB load.

```bash
bash ./run-5g-resource-optimization.sh
```

Useful options:

```bash
DURATION=90 STABILITY_DURATION=300 EMBB_PARALLEL=4 bash ./run-5g-resource-optimization.sh
URLLC_TARGET=10.46.0.1 bash ./run-5g-resource-optimization.sh
URLLC_TARGET=1.1.1.1 bash ./run-5g-resource-optimization.sh
```

For NCKH/reporting, prefer `URLLC_TARGET=10.46.0.1` to measure the slice-local path. Use Internet targets only as an additional end-to-end scenario.

The benchmark produces:

- Scenario A: uRLLC idle latency, jitter, and loss.
- Scenario B: eMBB-only throughput under the scaled broadband profile.
- Scenario C: uRLLC SLA while eMBB is saturated.
- Scenario D: sustained stability samples for Grafana/report screenshots.

Reports are written to `reports/` as Markdown and CSV.

For the report, interpret eMBB throughput carefully:

- The Open5GS UPF in this lab is userspace GTP-U, so its forwarding ceiling can be much lower than the configured theoretical 5G target.
- The benchmark therefore uses a scaled profile, where the question is whether the slicing policy protects uRLLC and allocates eMBB consistently at the lab's real data-plane capacity.
- If uRLLC jitter rises under eMBB load, check `docker exec upf-urllc tc qdisc show dev ogstun`; the expected uRLLC profile is `htb -> netem -> fq_codel`.

To debug a low eMBB result, run:

```bash
DURATION=20 FLOWS="1 2 4 8" bash ./scripts/debug-embb-throughput.sh
```

This prints four useful comparisons:

- Docker bridge baseline, not forced through the 5G tunnel.
- 5G tunnel upload, from UE to the iperf3 server.
- 5G tunnel download, using iperf3 reverse mode.
- `ogstun` counter throughput, to confirm whether the traffic is really crossing the UPF tunnel. Upload is compared with `ogstun` RX, while download is compared with `ogstun` TX.

Use the result like this:

- Bridge high but tunnel low means the bottleneck is UPF/GTP/VM CPU, not iperf3 itself.
- Upload high but download low points to the downlink/reverse path or UPF TX queue.
- Throughput dropping as flows increase means parallel TCP is overloading the userspace GTP path.
- `iperf3` Mbps and the matching `ogstun` direction should be close; if they diverge strongly, the test path is not clean.

Note that HTTP download and `iperf3 -R` both exercise the downlink path, but their TCP behavior is not identical. With `iperf3 -R -P 8`, the server sends eight downlink streams while the UE sends ACK traffic back through the uplink tunnel. This can make Open5GS process many bidirectional GTP flows at the same time. If one-flow reverse mode is acceptable but eight-flow reverse mode collapses, treat ACK/uplink feedback overhead and userspace GTP scheduling as likely causes.

Suggested report wording after the debug run:

```text
uRLLC achieved strong isolation, with a jitter isolation ratio close to 1.0, showing that HTB/fq_codel effectively protects the latency-sensitive slice in the testbed. Because the VM-based Open5GS UPF has a limited userspace GTP-U forwarding ceiling, the experiment uses a scaled resource profile instead of claiming hardware-grade 5G throughput. Within that scaled capacity, eMBB receives a stable broadband allocation while uRLLC keeps its latency and jitter SLA under eMBB saturation. The results support the correctness of the per-slice resource separation and optimization design.
```

## Web UI

- Open5GS WebUI: http://localhost:9999
- Prometheus: http://localhost:9090
- Grafana: http://localhost:3000

Default Grafana login: `admin` / `admin`

Open5GS WebUI default from the image is commonly `admin` / `1423`.

## Grafana Dashboard

Start the metric pusher:

```bash
nohup bash scripts/push-metrics.sh > /tmp/push-metrics.log 2>&1 &
```

Restart Grafana after changing dashboard/provisioning files:

```bash
docker compose up -d --force-recreate grafana
```

Open Grafana:

```text
http://localhost:3000
```

Go to `Dashboards` -> `5G Lab` -> `5G Network Slicing`.

The dashboard uses these PromQL queries:

```promql
rate(upf_embb_rx_bytes_total{job="upf_embb"}[30s]) * 8 / 1000000
rate(upf_embb_tx_bytes_total{job="upf_embb"}[30s]) * 8 / 1000000
rate(upf_urllc_rx_bytes_total{job="upf_urllc"}[30s]) * 8 / 1000000
rate(upf_urllc_tx_bytes_total{job="upf_urllc"}[30s]) * 8 / 1000000
```

Unit: Mbps.

If old non-`_total` metrics are still shown in Prometheus, clear the Pushgateway jobs and restart the pusher:

```bash
curl -X DELETE http://localhost:9091/metrics/job/upf_embb
curl -X DELETE http://localhost:9091/metrics/job/upf_urllc
pkill -f scripts/push-metrics.sh
nohup bash scripts/push-metrics.sh > /tmp/push-metrics.log 2>&1 &
```

If the pusher exits, check:

```bash
cat /tmp/push-metrics.log
sed -i 's/\r$//' scripts/push-metrics.sh
nohup bash scripts/push-metrics.sh > /tmp/push-metrics.log 2>&1 &
```

## Cleanup

```bash
docker compose down
```

To remove generated database/monitoring data:

```bash
docker compose down -v
sudo rm -rf mongodb_data prometheus_data grafana_data
```
