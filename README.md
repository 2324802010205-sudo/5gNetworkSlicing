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

The main compose file starts the 5G core, two UPFs, gNB, two UEs, Prometheus, Grafana, Pushgateway, Node Exporter, cAdvisor and a local eMBB HTTP traffic source.

## Fix UPF NAT/QoS

Run this after containers are up, or after restarting UPF/UE containers:

```bash
bash ./fix-upf.sh
```

The script keeps UPF gateway IPs aligned with `config/smf.yaml`:

- `upf-embb`: `10.45.0.1/16`
- `upf-urllc`: `10.46.0.1/16`

It also applies the optimized slice resource profiles:

- eMBB: 150 Mbps committed rate, 180 Mbps burst ceiling, radio-like delay/jitter for video and web traffic.
- uRLLC: 20 Mbps committed rate, 25 Mbps ceiling, very low delay/jitter and a short queue for latency-sensitive probes.

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

## Measure Slices

```bash
bash ./measure-urllc.sh
bash ./measure-embb.sh
```

## Run A Realistic Slice Demo

This demo drives the eMBB slice with local video-like HTTP download traffic while the uRLLC slice continuously measures latency, jitter and loss:

```bash
bash ./run-5g-slices-real-demo.sh
```

Useful options:

```bash
DURATION=300 bash ./run-5g-slices-real-demo.sh
VIDEO_URL=http://172.20.0.220:8080/embb.bin bash ./run-5g-slices-real-demo.sh
PING_TARGET=8.8.8.8 bash ./run-5g-slices-real-demo.sh
```

Expected behavior:

- eMBB should show much higher throughput and tolerate more delay because it represents mobile broadband/YouTube-like traffic.
- uRLLC defaults to `PING_TARGET=10.46.0.1`, the uRLLC UPF gateway, so the RTT reflects the slice path in the lab instead of public Internet latency.
- Use `PING_TARGET=1.1.1.1` only when you intentionally want to measure end-to-end Internet RTT through the slice.

The default eMBB source is `embb-traffic-source` at `172.20.0.220:8080`. This avoids public CDN blocking, TLS certificate issues and Internet variability while still sending downlink traffic through the eMBB UPF.

For a real browser/YouTube demo, run:

```bash
bash ./start-5g-youtube.sh
```

Then configure Firefox to use the SOCKS5 proxy printed by the script.

## Run The Research Benchmark

Use this benchmark when you need report-ready numbers for resource optimization and slice isolation:

```bash
bash ./run-5g-slicing-benchmark.sh
```

It validates the eMBB tunnel path, saturates eMBB with local HTTP traffic, then compares uRLLC latency/jitter/loss before and during eMBB saturation. Reports are written to `reports/` as Markdown and CSV.

Useful options:

```bash
DURATION=90 EMBB_PARALLEL=6 bash ./run-5g-slicing-benchmark.sh
EMBB_MODE=iperf3 DURATION=90 EMBB_PARALLEL=8 bash ./run-5g-slicing-benchmark.sh
EMBB_MODE=http DURATION=90 EMBB_PARALLEL=6 bash ./run-5g-slicing-benchmark.sh
URLLC_TARGET=10.46.0.1 bash ./run-5g-slicing-benchmark.sh
URLLC_TARGET=1.1.1.1 bash ./run-5g-slicing-benchmark.sh
```

For NCKH/reporting, prefer `URLLC_TARGET=10.46.0.1` to measure the slice-local path. Use Internet targets only as an additional end-to-end scenario.

The benchmark uses `iperf3` reverse TCP by default for eMBB throughput. This avoids the common false bottleneck from the Python HTTP traffic source. The HTTP source is still kept for video-like demo traffic and can be selected with `EMBB_MODE=http`.

For the report, interpret low eMBB throughput as follows:

- If HTTP is low but `iperf3` is near 100-150 Mbps, the bottleneck is the HTTP demo server/client path, not HTB.
- If both HTTP and `iperf3` stay low, the likely bottleneck is VM CPU scheduling, virtual NIC throughput, or Open5GS userspace GTP-U forwarding.
- If uRLLC jitter rises under eMBB load, check `docker exec upf-urllc tc qdisc show dev ogstun`; the expected uRLLC profile is `htb -> netem -> fq_codel`.

To debug a low eMBB result, run:

```bash
DURATION=20 FLOWS="1 2 4 8" bash ./scripts/debug-embb-throughput.sh
```

This prints four useful comparisons:

- Docker bridge baseline, not forced through the 5G tunnel.
- 5G tunnel upload, from UE to the iperf3 server.
- 5G tunnel download, using iperf3 reverse mode.
- `ogstun` counter throughput, to confirm whether the traffic is really crossing the UPF tunnel.

Use the result like this:

- Bridge high but tunnel low means the bottleneck is UPF/GTP/VM CPU, not iperf3 itself.
- Upload high but download low points to the downlink/reverse path or UPF TX queue.
- Throughput dropping as flows increase means parallel TCP is overloading the userspace GTP path.
- `iperf3` Mbps and `ogstun` Mbps should be close; if they diverge strongly, the test path is not clean.

Note that HTTP download and `iperf3 -R` both exercise the downlink path, but their TCP behavior is not identical. With `iperf3 -R -P 8`, the server sends eight downlink streams while the UE sends ACK traffic back through the uplink tunnel. This can make Open5GS process many bidirectional GTP flows at the same time. If one-flow reverse mode is acceptable but eight-flow reverse mode collapses, treat ACK/uplink feedback overhead and userspace GTP scheduling as likely causes.

Suggested report wording after the debug run:

```text
uRLLC achieved strong isolation, with a jitter isolation ratio close to 1.0, showing that HTB/fq_codel effectively protects the latency-sensitive slice in the testbed. The measured eMBB throughput remained below the 100-150 Mbps target because of testbed-layer limits, especially Open5GS userspace GTP-U overhead and VM CPU scheduling. This is a limitation of the softwarized 5G core environment and does not invalidate the slice resource isolation mechanism. The results support the correctness of the per-slice resource separation design.
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
