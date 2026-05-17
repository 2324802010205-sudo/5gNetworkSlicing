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

The main compose file starts the 5G core, two UPFs, gNB, two UEs, Prometheus, Grafana, Pushgateway, Node Exporter and cAdvisor.

## Fix UPF NAT/QoS

Run this after containers are up, or after restarting UPF/UE containers:

```bash
bash ./fix-upf.sh
```

The script keeps UPF gateway IPs aligned with `config/smf.yaml`:

- `upf-embb`: `10.45.0.1/16`
- `upf-urllc`: `10.46.0.1/16`

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
