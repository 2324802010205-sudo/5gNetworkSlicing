# All Project Files And Refactor Summary

File này tổng hợp lại project sau refactor: phần đầu là tóm tắt đã làm gì, phần sau là nội dung đầy đủ của các file text quan trọng trong repo.

Không nhúng chính `ALL_CONFIGS_FULL.md`, không nhúng `.git`, dữ liệu runtime (`mongodb_data`, `prometheus_data`, `grafana_data`, `reports`) hoặc binary cache (`__pycache__`).

## Tổng Hợp Đã Làm

- Refactor `docker-compose.yaml` sang mô hình profiles để máy nhẹ hơn.
- Profile mặc định là `core` trong `.env`, nên `docker compose up -d` chỉ chạy core 5G.
- Tách monitoring ra `monitoring`: Prometheus, Grafana, Pushgateway.
- Tách monitoring nặng ra `heavy-monitoring`: node-exporter, cadvisor.
- Tách traffic generator ra `traffic`: eMBB iperf server, URLLC iperf server, MQTT server.
- Tách Open5GS WebUI ra `webui`.
- Đổi restart policy sang biến `RESTART_POLICY`, mặc định `on-failure:3` để debug dễ hơn.
- Pin version image monitoring: Prometheus, Grafana, Pushgateway, node-exporter, cadvisor.
- Bỏ `GF_INSTALL_PLUGINS=grafana-clock-panel` để giảm phụ thuộc tải plugin khi chạy.
- Tăng Prometheus scrape/evaluation interval từ `5s` lên `15s`.
- Tăng Grafana dashboard refresh từ `5s` lên `15s`.
- Thêm `config/nssf.yaml` và service `nssf` cho 2 slice eMBB/URLLC.
- Cập nhật `config/amf.yaml` để AMF dùng NRF và NSSF.
- Giữ SMF map DNN/S-NSSAI sang 2 UPF: `internet -> upf-embb`, `internet2 -> upf-urllc`.
- Đồng bộ Pushgateway/Prometheus job label về `upf-embb` và `upf-urllc`.
- Sửa dashboard Grafana để query theo job label đúng, tránh lẫn eMBB và URLLC.
- Thêm `scripts/test-embb.sh` để test eMBB TCP throughput.
- Thêm `scripts/test-urllc.sh` để test URLLC UDP packet nhỏ.
- Thêm `scripts/test-mixed.sh` để chạy đồng thời eMBB tải nặng và URLLC.
- Thêm `scripts/controller/sla_dynamic_allocator.py`: thuật toán SLA-aware Dynamic Resource Allocation dùng Linux `tc` HTB + `fq_codel`, không dùng DRL.
- Viết lại `check-5g.sh` theo dạng PASS/WARN/FAIL, tập trung kiểm tra core và xem monitoring/traffic là optional.
- Viết lại `README.md` thành runbook: thành phần hệ thống, lệnh chạy nhẹ, monitoring, traffic test, controller, tiêu chí đánh giá.

## Cách Chạy Nhanh

```bash
docker compose up -d
bash ./check-5g.sh
docker compose --profile monitoring up -d prometheus grafana pushgateway
docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server
bash scripts/test-embb.sh
bash scripts/test-urllc.sh
bash scripts/test-mixed.sh
python3 scripts/controller/sla_dynamic_allocator.py --mode dynamic_sla_slicing --duration 120
```

## File Index

- `.env`
- `.gitignore`
- `README.md`
- `docker-compose.yaml`
- `config/amf.yaml`
- `config/ausf.yaml`
- `config/nrf.yaml`
- `config/nssf.yaml`
- `config/pcf.yaml`
- `config/prometheus.yml`
- `config/smf.yaml`
- `config/udm.yaml`
- `config/udr.yaml`
- `config/upf-embb.yaml`
- `config/upf-urllc.yaml`
- `config-ueransim/gnb.yaml`
- `config-ueransim/ue-embb.yaml`
- `config-ueransim/ue-urllc.yaml`
- `config-ueransim/all-configs.yaml`
- `grafana/provisioning/dashboards/dashboards.yml`
- `grafana/provisioning/datasources/prometheus.yml`
- `grafana-dashboard-5g.json`
- `grafana-5g-slicing-dashboard.json`
- `grafana-bandwidth-dashboard.json`
- `grafana/dashboards/5g-network-slicing.json`
- `check-5g.sh`
- `check-5g.ps1`
- `fix-upf.sh`
- `run-5g-resource-optimization.sh`
- `scripts/apply-slice-qos.sh`
- `scripts/debug-embb-throughput.sh`
- `scripts/push-metrics.sh`
- `scripts/test-embb.sh`
- `scripts/test-urllc.sh`
- `scripts/test-mixed.sh`
- `scripts/upf-embb-start.sh`
- `scripts/upf-urllc-start.sh`
- `scripts/controller/sla_dynamic_allocator.py`

## .env

```dotenv
COMPOSE_PROFILES=core
RESTART_POLICY=on-failure:3

```

## .gitignore

```gitignore
grafana_data/
prometheus_data/
mongodb_data/
reports/
*.pcap

```

## README.md

```markdown
# 5G Network Slicing Lab

Docker Compose lab for Open5GS 2.7.5 + UERANSIM 3.2.6 with two research slices:

- eMBB: UE `ue-embb`, DNN `internet`, S-NSSAI `SST=1, SD=000001`, subnet `10.45.0.0/16`.
- URLLC: UE `ue-urllc`, DNN `internet2`, S-NSSAI `SST=2, SD=000002`, subnet `10.46.0.0/16`.

The goal is not only to draw nice Grafana charts. The lab is shaped to prove resource optimization behavior: when eMBB creates heavy broadband load, URLLC should keep latency/loss inside SLA after static or dynamic allocation is applied.

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

Run URLLC UDP small packets:

```bash
bash scripts/test-urllc.sh
```

Run mixed contention:

```bash
bash scripts/test-mixed.sh
```

The eMBB flow represents 4K/8K video, cloud gaming, or large download pressure. The URLLC flow represents robot/camera/sensor control messages: smaller packets, lower bitrate, stricter latency/loss target.

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

```

## docker-compose.yaml

```yaml
x-open5gs-image: &open5gs_image gradiant/open5gs:2.7.5
x-ueransim-image: &ueransim_image gradiant/ueransim:3.2.6
x-restart-policy: &restart_policy "${RESTART_POLICY:-on-failure:3}"

networks:
  br-5gcore:
    driver: bridge
    ipam:
      driver: default
      config:
        - subnet: 172.20.0.0/16
          gateway: 172.20.0.1

services:
  mongo:
    image: mongo:6-jammy
    container_name: mongo
    profiles: ["core"]
    restart: *restart_policy
    command: ["mongod", "--bind_ip_all"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.5
    volumes:
      - ./mongodb_data:/data/db
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet --eval 'db.adminCommand({ ping: 1 }).ok' mongodb://127.0.0.1:27017/admin | grep -q 1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 30s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M

  nrf:
    image: *open5gs_image
    container_name: nrf
    profiles: ["core"]
    command: open5gs-nrfd -c /opt/open5gs/etc/open5gs/nrf.yaml
    depends_on:
      mongo:
        condition: service_healthy
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.10
    volumes:
      - ./config/nrf.yaml:/opt/open5gs/etc/open5gs/nrf.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 192M

  nssf:
    image: *open5gs_image
    container_name: nssf
    profiles: ["core"]
    command: open5gs-nssfd -c /opt/open5gs/etc/open5gs/nssf.yaml
    depends_on:
      - nrf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.15
    volumes:
      - ./config/nssf.yaml:/opt/open5gs/etc/open5gs/nssf.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 192M

  amf:
    image: *open5gs_image
    container_name: amf
    profiles: ["core"]
    command: open5gs-amfd -c /opt/open5gs/etc/open5gs/amf.yaml
    depends_on:
      - nrf
      - nssf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.20
    volumes:
      - ./config/amf.yaml:/opt/open5gs/etc/open5gs/amf.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.4'
          memory: 384M

  smf:
    image: *open5gs_image
    container_name: smf
    profiles: ["core"]
    command: open5gs-smfd -c /opt/open5gs/etc/open5gs/smf.yaml
    depends_on:
      - nrf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.30
    volumes:
      - ./config/smf.yaml:/opt/open5gs/etc/open5gs/smf.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.4'
          memory: 384M

  ausf:
    image: *open5gs_image
    container_name: ausf
    profiles: ["core"]
    command: open5gs-ausfd -c /opt/open5gs/etc/open5gs/ausf.yaml
    depends_on:
      - nrf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.40
    volumes:
      - ./config/ausf.yaml:/opt/open5gs/etc/open5gs/ausf.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 192M

  udm:
    image: *open5gs_image
    container_name: udm
    profiles: ["core"]
    command: open5gs-udmd -c /opt/open5gs/etc/open5gs/udm.yaml
    depends_on:
      - nrf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.50
    volumes:
      - ./config/udm.yaml:/opt/open5gs/etc/open5gs/udm.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 192M

  udr:
    image: *open5gs_image
    container_name: udr
    profiles: ["core"]
    command: open5gs-udrd -c /opt/open5gs/etc/open5gs/udr.yaml
    depends_on:
      - mongo
      - nrf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.60
    volumes:
      - ./config/udr.yaml:/opt/open5gs/etc/open5gs/udr.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 192M

  pcf:
    image: *open5gs_image
    container_name: pcf
    profiles: ["core"]
    command: open5gs-pcfd -c /opt/open5gs/etc/open5gs/pcf.yaml
    depends_on:
      - nrf
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.70
    volumes:
      - ./config/pcf.yaml:/opt/open5gs/etc/open5gs/pcf.yaml:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.2'
          memory: 192M

  upf-embb:
    image: *open5gs_image
    container_name: upf-embb
    profiles: ["core"]
    user: root
    entrypoint: ["/bin/bash", "/scripts/upf-embb-start.sh"]
    privileged: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - IPV4_TUN_ADDR=10.45.0.1/16
      - IPV4_TUN_SUBNET=10.45.0.0/16
      - IPV6_TUN_ADDR=cafe::1/64
      - ENABLE_NAT=true
      - OGSTUN_TXQUEUELEN=4096
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.100
    volumes:
      - ./config/upf-embb.yaml:/opt/open5gs/etc/open5gs/upf-embb.yaml:ro
      - ./scripts/upf-embb-start.sh:/scripts/upf-embb-start.sh:ro
      - ./scripts/apply-slice-qos.sh:/scripts/apply-slice-qos.sh:ro
    restart: *restart_policy
    cpu_shares: 2048
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 768M

  upf-urllc:
    image: *open5gs_image
    container_name: upf-urllc
    profiles: ["core"]
    user: root
    entrypoint: ["/bin/bash", "/scripts/upf-urllc-start.sh"]
    privileged: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - IPV4_TUN_ADDR=10.46.0.1/16
      - IPV4_TUN_SUBNET=10.46.0.0/16
      - IPV6_TUN_ADDR=cafe::2/64
      - ENABLE_NAT=true
      - OGSTUN_TXQUEUELEN=512
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.101
    volumes:
      - ./config/upf-urllc.yaml:/opt/open5gs/etc/open5gs/upf-urllc.yaml:ro
      - ./scripts/upf-urllc-start.sh:/scripts/upf-urllc-start.sh:ro
      - ./scripts/apply-slice-qos.sh:/scripts/apply-slice-qos.sh:ro
    restart: *restart_policy
    cpu_shares: 2048
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 768M

  gnb:
    image: *ueransim_image
    container_name: gnb
    profiles: ["core"]
    entrypoint: ["nr-gnb", "-c", "/mnt/ueransim/gnb.yaml"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.1.10
    volumes:
      - ./config-ueransim:/mnt/ueransim
    cap_add:
      - NET_ADMIN
    depends_on:
      - amf
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.35'
          memory: 384M

  ue-embb:
    image: *ueransim_image
    container_name: ue-embb
    profiles: ["core"]
    entrypoint: ["nr-ue", "-c", "/mnt/ueransim/ue-embb.yaml"]
    privileged: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    networks:
      - br-5gcore
    volumes:
      - ./config-ueransim:/mnt/ueransim
    depends_on:
      - gnb
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 192M

  ue-urllc:
    image: *ueransim_image
    container_name: ue-urllc
    profiles: ["core"]
    entrypoint: ["nr-ue", "-c", "/mnt/ueransim/ue-urllc.yaml"]
    privileged: true
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    networks:
      - br-5gcore
    volumes:
      - ./config-ueransim:/mnt/ueransim
    depends_on:
      - gnb
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 192M

  prometheus:
    image: prom/prometheus:v2.54.1
    container_name: prometheus
    profiles: ["monitoring"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.210
    volumes:
      - ./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus_data:/prometheus
    ports:
      - "9090:9090"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=6h
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.35'
          memory: 384M

  grafana:
    image: grafana/grafana:11.2.0
    container_name: grafana
    profiles: ["monitoring"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.211
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    volumes:
      - ./grafana_data:/var/lib/grafana
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
    depends_on:
      - prometheus
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.35'
          memory: 384M

  pushgateway:
    image: prom/pushgateway:v1.9.0
    container_name: pushgateway
    profiles: ["monitoring"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.212
    ports:
      - "9091:9091"
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.15'
          memory: 96M

  node-exporter:
    image: prom/node-exporter:v1.8.2
    container_name: node-exporter
    profiles: ["heavy-monitoring"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.213
    ports:
      - "9100:9100"
    command:
      - --path.rootfs=/host
    volumes:
      - /:/host:ro,rslave
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.15'
          memory: 96M

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    profiles: ["heavy-monitoring"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.214
    privileged: true
    healthcheck:
      disable: true
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 192M

  webui:
    image: gradiant/open5gs-webui:2.7.5
    container_name: webui
    profiles: ["webui"]
    depends_on:
      mongo:
        condition: service_healthy
    environment:
      - DB_URI=mongodb://mongo:27017/open5gs
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.200
    ports:
      - "9999:9999"
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 192M

  embb-iperf-server:
    image: networkstatic/iperf3:latest
    container_name: embb-iperf-server
    profiles: ["traffic"]
    command: ["-s", "-p", "5201"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.221
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 128M

  urllc-iperf-server:
    image: networkstatic/iperf3:latest
    container_name: urllc-iperf-server
    profiles: ["traffic"]
    command: ["-s", "-p", "5202"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.222
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.25'
          memory: 96M

  mqtt-server:
    image: eclipse-mosquitto:2.0.18
    container_name: mqtt-server
    profiles: ["traffic"]
    command: ["mosquitto", "-c", "/mosquitto-no-auth.conf"]
    networks:
      br-5gcore:
        ipv4_address: 172.20.0.223
    ports:
      - "1883:1883"
    restart: *restart_policy
    deploy:
      resources:
        limits:
          cpus: '0.15'
          memory: 64M

```

## config/amf.yaml

```yaml
amf:
  amf_name: open5gs-amf
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
      nssf:
        - uri: http://nssf:7777
  ngap:
    server:
      - dev: eth0
  metrics:
    server:
      - dev: eth0
        port: 9090
  guami:
    - plmn_id:
        mcc: 901
        mnc: 70
      amf_id:
        region: 2
        set: 1
  tai:
    - plmn_id:
        mcc: 901
        mnc: 70
      tac: 1
  plmn_support:
    - plmn_id:
        mcc: 901
        mnc: 70
      s_nssai:
        - sst: 1  # eMBB
          sd: 0x000001
        - sst: 2  # URLLC
          sd: 0x000002
  security:
    integrity_order:
      - NIA2
      - NIA1
      - NIA0
    ciphering_order:
      - NEA2
      - NEA1
      - NEA0
  network_name:
    full: Open5GS
    short: Next
  amf_name: open5gs-amf
  time:
    t3502:
      value: 720
    t3512:
      value: 540
  logger:
    level: info

```

## config/ausf.yaml

```yaml
ausf:
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
  logger:
    level: info

```

## config/nrf.yaml

```yaml
nrf:
  sbi:
    server:
      - dev: eth0
        port: 7777
  logger:
    level: info

```

## config/nssf.yaml

```yaml
nssf:
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
      nsi:
        - uri: http://nrf:7777
          s_nssai:
            sst: 1
            sd: 000001
        - uri: http://nrf:7777
          s_nssai:
            sst: 2
            sd: 000002
  nsi:
    - uri: http://nrf:7777
      s_nssai:
        sst: 1
        sd: 000001
      tai:
        plmn_id:
          mcc: 901
          mnc: 70
        tac: 1
    - uri: http://nrf:7777
      s_nssai:
        sst: 2
        sd: 000002
      tai:
        plmn_id:
          mcc: 901
          mnc: 70
        tac: 1
  logger:
    level: info

```

## config/pcf.yaml

```yaml
pcf:
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
  metrics:
    server:
      - dev: eth0
        port: 9090
  policy:
    - plmn_id:
        mcc: 901
        mnc: 70
      slice:
        - sst: 1
          sd: 0x000001
          default_indicator: true
          session:
            - name: internet
              type: 3
              qos:
                index: 9
                arp:
                  priority_level: 8
                  pre_emption_capability: 1
                  pre_emption_vulnerability: 1
              ambr:
                downlink:
                  value: 200
                  unit: 2
                uplink:
                  value: 100
                  unit: 2
        - sst: 2
          sd: 0x000002
          session:
            - name: internet2
              type: 3
              qos:
                index: 82
                arp:
                  priority_level: 2
                  pre_emption_capability: 1
                  pre_emption_vulnerability: 2
              ambr:
                downlink:
                  value: 50
                  unit: 2
                uplink:
                  value: 50
                  unit: 2

```

## config/prometheus.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    monitor: '5g-network-monitor'

scrape_configs:
  - job_name: 'node-exporter'
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          group: 'infrastructure'

  - job_name: 'cadvisor'
    static_configs:
      - targets: ['cadvisor:8080']
        labels:
          group: 'containers'

  - job_name: 'amf'
    static_configs:
      - targets: ['amf:9090']
        labels:
          group: '5g-core'
          function: 'amf'

  - job_name: 'smf'
    static_configs:
      - targets: ['smf:9090']
        labels:
          group: '5g-core'
          function: 'smf'

  - job_name: 'upf-embb'
    static_configs:
      - targets: ['upf-embb:9090']
        labels:
          group: '5g-upf'
          slice: 'embb'

  - job_name: 'upf-urllc'
    static_configs:
      - targets: ['upf-urllc:9090']
        labels:
          group: '5g-upf'
          slice: 'urllc'

  - job_name: 'pcf'
    static_configs:
      - targets: ['pcf:9090']
        labels:
          group: '5g-core'
          function: 'pcf'
  - job_name: 'pushgateway'
    honor_labels: true
    static_configs:
      - targets: ['pushgateway:9091']
        labels:
          group: '5g-upf-metrics'

```

## config/smf.yaml

```yaml
smf:
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
  pfcp:
    server:
      - dev: eth0
    client:
      upf:
        - address: upf-embb
          dnn: internet
        - address: upf-urllc
          dnn: internet2
  gtpc:
    server:
      - dev: eth0
  gtpu:
    server:
      - dev: eth0
  metrics:
    server:
      - dev: eth0
        port: 9090
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
      dnn: internet
    - subnet: 10.46.0.0/16
      gateway: 10.46.0.1
      dnn: internet2
  dns:
    - 8.8.8.8
    - 8.8.4.4
  mtu: 1400
  ctf:
    enabled: auto
  info:
    - s_nssai:
        - sst: 1
          sd: 000001
          dnn:
            - internet
        - sst: 2
          sd: 000002
          dnn:
            - internet2

```

## config/udm.yaml

```yaml
udm:
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
      udr:
        - uri: http://udr:7777
  logger:
    level: info

```

## config/udr.yaml

```yaml
udr:
  sbi:
    server:
      - dev: eth0
        port: 7777
    client:
      nrf:
        - uri: http://nrf:7777
  mongodb:
    name: open5gs
    url: mongodb://mongo:27017/open5gs
  logger:
    level: info
  global:
    max:
      ue: 2048

```

## config/upf-embb.yaml

```yaml
upf:
  pfcp:
    server:
      - dev: eth0
  gtpu:
    server:
      - dev: eth0
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
      dnn: internet
  metrics:
    server:
      - dev: eth0
        port: 9090
  logger:
    level: info

```

## config/upf-urllc.yaml

```yaml
upf:
  pfcp:
    server:
      - dev: eth0
  gtpu:
    server:
      - dev: eth0
  session:
    - subnet: 10.46.0.0/16
      gateway: 10.46.0.1
      dnn: internet2
  metrics:
    server:
      - dev: eth0
        port: 9090
  logger:
    level: info

```

## config-ueransim/gnb.yaml

```yaml
mcc: '901'
mnc: '70'
nci: '0x000000010'
idLength: 32
tac: 1

# gNB sử dụng IP tĩnh 172.20.1.10
linkIp: 172.20.1.10
ngapIp: 172.20.1.10
gtpIp: 172.20.1.10

# AMF configuration - kết nối tới AMF IP tĩnh
amfConfigs:
  - address: 172.20.0.20
    port: 38412

# Hỗ trợ 2 slices: eMBB, URLLC
slices:
  - sst: 1  # eMBB - Enhanced Mobile Broadband
    sd: 0x000001
  - sst: 2  # URLLC - Ultra-Reliable Low-Latency
    sd: 0x000002

ignoreStreamIds: true

```

## config-ueransim/ue-embb.yaml

```yaml
# UE Configuration for eMBB (Enhanced Mobile Broadband)
# Use case: 4K/8K video streaming, AR/VR, Cloud gaming

supi: 'imsi-901700000000001'
mcc: '901'
mnc: '70'
key: '465B5CE8B199B49FAA5F0A2EE238A6BC'
op: 'E8ED289DEBA952E4283B54E88E6183CA'
opType: 'OPC'
amf: '8000'
imei: '356938035643801'
imeiSv: '4370816125816151'

# Dynamic gNB discovery
gnbSearchList:
  - gnb

uacAic:
  mps: false
  mcs: false

uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 1
      sd: 0x000001

configured-nssai:
  - sst: 1
    sd: 0x000001

default-nssai:
  - sst: 1
    sd: 0x000001

integrity:
  IA1: true
  IA2: true
  IA3: true

ciphering:
  EA1: true
  EA2: true
  EA3: true

integrityMaxRate:
  uplink: 'full'
  downlink: 'full'

```

## config-ueransim/ue-urllc.yaml

```yaml
# UE Configuration for URLLC (Ultra-Reliable Low-Latency Communications)
# Use case: Autonomous vehicles, Industrial automation, Remote surgery

supi: 'imsi-901700000000002'
mcc: '901'
mnc: '70'
key: '465B5CE8B199B49FAA5F0A2EE238A6BC'
op: 'E8ED289DEBA952E4283B54E88E6183CA'
opType: 'OPC'
amf: '8000'
imei: '356938035643802'
imeiSv: '4370816125816152'

# Dynamic gNB discovery
gnbSearchList:
  - gnb

uacAic:
  mps: true  # Mission critical
  mcs: true

uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: 'internet2'
    slice:
      sst: 2
      sd: 0x000002

configured-nssai:
  - sst: 2
    sd: 0x000002

default-nssai:
  - sst: 2
    sd: 0x000002

integrity:
  IA1: true
  IA2: true
  IA3: true

ciphering:
  EA1: true
  EA2: true
  EA3: true

integrityMaxRate:
  uplink: 'full'
  downlink: 'full'

```

## config-ueransim/all-configs.yaml

```yaml
# Combined UERANSIM configuration files
# Source: config-ueransim/gnb.yaml
---
mcc: '901'
mnc: '70'
nci: '0x000000010'
idLength: 32
tac: 1

# gNB sử dụng IP tĩnh 172.20.1.10
linkIp: 172.20.1.10
ngapIp: 172.20.1.10
gtpIp: 172.20.1.10

# AMF configuration - kết nối tới AMF IP tĩnh
amfConfigs:
  - address: 172.20.0.20
    port: 38412

# Hỗ trợ 2 slices: eMBB, URLLC
slices:
  - sst: 1  # eMBB - Enhanced Mobile Broadband
    sd: 0x000001
  - sst: 2  # URLLC - Ultra-Reliable Low-Latency
    sd: 0x000002

ignoreStreamIds: true

# Source: config-ueransim/ue-embb.yaml
---
# UE Configuration for eMBB (Enhanced Mobile Broadband)
# Use case: 4K/8K video streaming, AR/VR, Cloud gaming

supi: 'imsi-901700000000001'
mcc: '901'
mnc: '70'
key: '465B5CE8B199B49FAA5F0A2EE238A6BC'
op: 'E8ED289DEBA952E4283B54E88E6183CA'
opType: 'OPC'
amf: '8000'
imei: '356938035643801'
imeiSv: '4370816125816151'

# Dynamic gNB discovery
gnbSearchList:
  - gnb

uacAic:
  mps: false
  mcs: false

uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: 'internet'
    slice:
      sst: 1
      sd: 0x000001

configured-nssai:
  - sst: 1
    sd: 0x000001

default-nssai:
  - sst: 1
    sd: 0x000001

integrity:
  IA1: true
  IA2: true
  IA3: true

ciphering:
  EA1: true
  EA2: true
  EA3: true

integrityMaxRate:
  uplink: 'full'
  downlink: 'full'

# Source: config-ueransim/ue-urllc.yaml
---
# UE Configuration for URLLC (Ultra-Reliable Low-Latency Communications)
# Use case: Autonomous vehicles, Industrial automation, Remote surgery

supi: 'imsi-901700000000002'
mcc: '901'
mnc: '70'
key: '465B5CE8B199B49FAA5F0A2EE238A6BC'
op: 'E8ED289DEBA952E4283B54E88E6183CA'
opType: 'OPC'
amf: '8000'
imei: '356938035643802'
imeiSv: '4370816125816152'

# Dynamic gNB discovery
gnbSearchList:
  - gnb

uacAic:
  mps: true  # Mission critical
  mcs: true

uacAcc:
  normalClass: 0
  class11: false
  class12: false
  class13: false
  class14: false
  class15: false

sessions:
  - type: 'IPv4'
    apn: 'internet2'
    slice:
      sst: 2
      sd: 0x000002

configured-nssai:
  - sst: 2
    sd: 0x000002

default-nssai:
  - sst: 2
    sd: 0x000002

integrity:
  IA1: true
  IA2: true
  IA3: true

ciphering:
  EA1: true
  EA2: true
  EA3: true

integrityMaxRate:
  uplink: 'full'
  downlink: 'full'

```

## grafana/provisioning/dashboards/dashboards.yml

```yaml
apiVersion: 1

providers:
  - name: 5g-slicing
    orgId: 1
    folder: 5G Lab
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards

```

## grafana/provisioning/datasources/prometheus.yml

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    uid: prometheus
    isDefault: true
    editable: true

```

## grafana-dashboard-5g.json

```json
{
  "dashboard": {
    "title": "5G Network Slicing - eMBB vs URLLC",
    "tags": ["5g", "network-slicing"],
    "timezone": "browser",
    "panels": [
      {
        "id": 1,
        "title": "eMBB Throughput (Mbps)",
        "type": "graph",
        "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
        "targets": [
          {
            "expr": "rate(fivegs_ep_n3_gtp_indatapktn3upf{job=\"upf-embb\"}[1m])",
            "legendFormat": "eMBB Incoming Packets",
            "refId": "A"
          },
          {
            "expr": "rate(fivegs_ep_n3_gtp_outdatapktn3upf{job=\"upf-embb\"}[1m])",
            "legendFormat": "eMBB Outgoing Packets",
            "refId": "B"
          }
        ],
        "yaxes": [
          {"format": "Mbits", "label": "Throughput"},
          {"format": "short"}
        ]
      },
      {
        "id": 2,
        "title": "URLLC Throughput (Mbps)",
        "type": "graph",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
        "targets": [
          {
            "expr": "rate(fivegs_ep_n3_gtp_indatapktn3upf{job=\"upf-urllc\"}[1m])",
            "legendFormat": "URLLC Incoming Packets",
            "refId": "A"
          },
          {
            "expr": "rate(fivegs_ep_n3_gtp_outdatapktn3upf{job=\"upf-urllc\"}[1m])",
            "legendFormat": "URLLC Outgoing Packets",
            "refId": "B"
          }
        ],
        "yaxes": [
          {"format": "Mbits", "label": "Throughput"},
          {"format": "short"}
        ]
      },
      {
        "id": 3,
        "title": "Active Sessions",
        "type": "stat",
        "gridPos": {"h": 4, "w": 6, "x": 0, "y": 8},
        "targets": [
          {
            "expr": "fivegs_upffunction_upf_sessionnbr{job=\"upf-embb\"}",
            "legendFormat": "eMBB Sessions",
            "refId": "A"
          }
        ],
        "options": {
          "colorMode": "value",
          "graphMode": "area"
        }
      },
      {
        "id": 4,
        "title": "URLLC Sessions",
        "type": "stat",
        "gridPos": {"h": 4, "w": 6, "x": 6, "y": 8},
        "targets": [
          {
            "expr": "fivegs_upffunction_upf_sessionnbr{job=\"upf-urllc\"}",
            "legendFormat": "URLLC Sessions",
            "refId": "A"
          }
        ],
        "options": {
          "colorMode": "value",
          "graphMode": "area"
        }
      },
      {
        "id": 5,
        "title": "Throughput Comparison",
        "type": "graph",
        "gridPos": {"h": 8, "w": 12, "x": 12, "y": 8},
        "targets": [
          {
            "expr": "fivegs_upffunction_upf_sessionnbr",
            "legendFormat": "{{job}}",
            "refId": "A"
          }
        ],
        "yaxes": [
          {"format": "Mbits", "label": "Throughput"},
          {"format": "short"}
        ]
      },
      {
        "id": 6,
        "title": "Packet Errors",
        "type": "graph",
        "gridPos": {"h": 6, "w": 12, "x": 0, "y": 12},
        "targets": [
          {
            "expr": "fivegs_upffunction_upf_qosflows",
            "legendFormat": "{{job}} - {{dnn}}",
            "refId": "A"
          }
        ]
      }
    ],
    "refresh": "15s",
    "time": {"from": "now-15m", "to": "now"},
    "timepicker": {"refresh_intervals": ["15s", "30s", "1m", "5m"]}
  }
}

```

## grafana-5g-slicing-dashboard.json

```json
{
  "title": "5G Network Slicing - QoS Monitor",
  "uid": "5g-slicing-qos",
  "timezone": "browser",
  "refresh": "15s",
  "time": { "from": "now-15m", "to": "now" },
  "panels": [
    {
      "id": 1,
      "title": "Active UEs",
      "type": "stat",
      "gridPos": { "x": 0, "y": 0, "w": 4, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "ues_active",
        "legendFormat": "UEs"
      }],
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "textMode": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "red", "value": 0 },
              { "color": "green", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "id": 2,
      "title": "Active PFCP Sessions",
      "type": "stat",
      "gridPos": { "x": 4, "y": 0, "w": 4, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "pfcp_sessions_active",
        "legendFormat": "Sessions"
      }],
      "options": {
        "colorMode": "background",
        "graphMode": "none"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "red", "value": 0 },
              { "color": "green", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "id": 3,
      "title": "eMBB Slice Sessions (SST:1)",
      "type": "stat",
      "gridPos": { "x": 8, "y": 0, "w": 4, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "fivegs_smffunction_sm_sessionnbr{snssai=~\"1-.*\"}",
        "legendFormat": "eMBB"
      }],
      "options": { "colorMode": "background", "graphMode": "none" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "red", "value": 0 },
              { "color": "blue", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "id": 4,
      "title": "URLLC Slice Sessions (SST:2)",
      "type": "stat",
      "gridPos": { "x": 12, "y": 0, "w": 4, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "fivegs_smffunction_sm_sessionnbr{snssai=~\"2-.*\"}",
        "legendFormat": "URLLC"
      }],
      "options": { "colorMode": "background", "graphMode": "none" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "red", "value": 0 },
              { "color": "orange", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "id": 5,
      "title": "UPF QoS Flows per Slice",
      "type": "bargauge",
      "gridPos": { "x": 16, "y": 0, "w": 8, "h": 4 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "fivegs_upffunction_upf_qosflows{dnn=\"internet\"}",
          "legendFormat": "eMBB (DNN: internet)"
        },
        {
          "datasource": "prometheus",
          "expr": "fivegs_upffunction_upf_qosflows{dnn=\"internet2\"}",
          "legendFormat": "URLLC (DNN: internet2)"
        }
      ],
      "options": { "orientation": "horizontal" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" }
        }
      }
    },
    {
      "id": 6,
      "title": "SMF Sessions theo Slice (Timeline)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 4, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "fivegs_smffunction_sm_sessionnbr{snssai=~\"1-.*\"}",
          "legendFormat": "eMBB SST:1"
        },
        {
          "datasource": "prometheus",
          "expr": "fivegs_smffunction_sm_sessionnbr{snssai=~\"2-.*\"}",
          "legendFormat": "URLLC SST:2"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      },
      "options": { "legend": { "displayMode": "list", "placement": "bottom" } }
    },
    {
      "id": 7,
      "title": "PFCP Sessions Active (Timeline)",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 4, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "pfcp_sessions_active",
          "legendFormat": "PFCP Sessions"
        },
        {
          "datasource": "prometheus",
          "expr": "ues_active",
          "legendFormat": "Active UEs"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      }
    },
    {
      "id": 8,
      "title": "UPF eMBB - GTP Packets (N3 Interface)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 12, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "rate(fivegs_ep_n3_gtp_indatapktn3upf[1m])",
          "legendFormat": "eMBB RX packets/s"
        },
        {
          "datasource": "prometheus",
          "expr": "rate(fivegs_ep_n3_gtp_outdatapktn3upf[1m])",
          "legendFormat": "eMBB TX packets/s"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "pps",
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      }
    },
    {
      "id": 9,
      "title": "UPF URLLC - GTP Packets (N3 Interface)",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 12, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "rate(fivegs_ep_n3_gtp_indatapktn3upf[1m])",
          "legendFormat": "URLLC RX packets/s"
        },
        {
          "datasource": "prometheus",
          "expr": "rate(fivegs_ep_n3_gtp_outdatapktn3upf[1m])",
          "legendFormat": "URLLC TX packets/s"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "pps",
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      }
    },
    {
      "id": 10,
      "title": "N4 Session Establishments",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 20, "w": 24, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "fivegs_upffunction_sm_n4sessionestabreq",
          "legendFormat": "eMBB N4 Session Req"
        },
        {
          "datasource": "prometheus",
          "expr": "fivegs_upffunction_sm_n4sessionestabreq",
          "legendFormat": "URLLC N4 Session Req"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      }
    }
  ],
  "schemaVersion": 38,
  "version": 1
}

```

## grafana-bandwidth-dashboard.json

```json
{
  "title": "5G Network Slicing - Bandwidth Monitor",
  "uid": "5g-bandwidth",
  "timezone": "browser",
  "refresh": "15s",
  "time": { "from": "now-15m", "to": "now" },
  "panels": [
    {
      "id": 1,
      "title": "eMBB TX Bandwidth (Mbps)",
      "type": "stat",
      "gridPos": { "x": 0, "y": 0, "w": 6, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "rate(upf_embb_tx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
        "legendFormat": "eMBB TX Mbps"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "Mbps",
          "decimals": 2,
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "green", "value": 0 },
              { "color": "yellow", "value": 50 },
              { "color": "red", "value": 90 }
            ]
          }
        }
      },
      "options": { "colorMode": "background", "graphMode": "area" }
    },
    {
      "id": 2,
      "title": "eMBB RX Bandwidth (Mbps)",
      "type": "stat",
      "gridPos": { "x": 6, "y": 0, "w": 6, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "rate(upf_embb_rx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
        "legendFormat": "eMBB RX Mbps"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "Mbps",
          "decimals": 2,
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "blue", "value": 0 },
              { "color": "yellow", "value": 50 },
              { "color": "red", "value": 90 }
            ]
          }
        }
      },
      "options": { "colorMode": "background", "graphMode": "area" }
    },
    {
      "id": 3,
      "title": "URLLC TX Bandwidth (Mbps)",
      "type": "stat",
      "gridPos": { "x": 12, "y": 0, "w": 6, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "rate(upf_urllc_tx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
        "legendFormat": "URLLC TX Mbps"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "Mbps",
          "decimals": 2,
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "green", "value": 0 },
              { "color": "yellow", "value": 25 },
              { "color": "red", "value": 45 }
            ]
          }
        }
      },
      "options": { "colorMode": "background", "graphMode": "area" }
    },
    {
      "id": 4,
      "title": "URLLC RX Bandwidth (Mbps)",
      "type": "stat",
      "gridPos": { "x": 18, "y": 0, "w": 6, "h": 4 },
      "targets": [{
        "datasource": "prometheus",
        "expr": "rate(upf_urllc_rx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
        "legendFormat": "URLLC RX Mbps"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "Mbps",
          "decimals": 2,
          "color": { "mode": "thresholds" },
          "thresholds": {
            "steps": [
              { "color": "orange", "value": 0 },
              { "color": "yellow", "value": 25 },
              { "color": "red", "value": 45 }
            ]
          }
        }
      },
      "options": { "colorMode": "background", "graphMode": "area" }
    },
    {
      "id": 5,
      "title": "Bandwidth So Sánh 2 Slice - TX (Mbps)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 4, "w": 24, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "rate(upf_embb_tx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
          "legendFormat": "eMBB TX (max 100Mbps)"
        },
        {
          "datasource": "prometheus",
          "expr": "rate(upf_urllc_tx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
          "legendFormat": "URLLC TX (max 50Mbps)"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "Mbps",
          "decimals": 2,
          "custom": { "lineWidth": 2, "fillOpacity": 15 },
          "color": { "mode": "palette-classic" }
        }
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom" },
        "tooltip": { "mode": "multi" }
      }
    },
    {
      "id": 6,
      "title": "Bandwidth So Sánh 2 Slice - RX (Mbps)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 12, "w": 24, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "rate(upf_embb_rx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
          "legendFormat": "eMBB RX"
        },
        {
          "datasource": "prometheus",
          "expr": "rate(upf_urllc_rx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
          "legendFormat": "URLLC RX"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "Mbps",
          "decimals": 2,
          "custom": { "lineWidth": 2, "fillOpacity": 15 },
          "color": { "mode": "palette-classic" }
        }
      },
      "options": {
        "legend": { "displayMode": "list", "placement": "bottom" },
        "tooltip": { "mode": "multi" }
      }
    },
    {
      "id": 7,
      "title": "Total Data Volume - eMBB vs URLLC (MB)",
      "type": "timeseries",
      "gridPos": { "x": 0, "y": 20, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "upf_embb_tx_bytes_total{job=\"upf-embb\"} / 1000000",
          "legendFormat": "eMBB Total TX (MB)"
        },
        {
          "datasource": "prometheus",
          "expr": "upf_urllc_tx_bytes_total{job=\"upf-urllc\"} / 1000000",
          "legendFormat": "URLLC Total TX (MB)"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "MB",
          "decimals": 2,
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      }
    },
    {
      "id": 8,
      "title": "Active UEs & Sessions",
      "type": "timeseries",
      "gridPos": { "x": 12, "y": 20, "w": 12, "h": 8 },
      "targets": [
        {
          "datasource": "prometheus",
          "expr": "ues_active",
          "legendFormat": "Active UEs"
        },
        {
          "datasource": "prometheus",
          "expr": "pfcp_sessions_active",
          "legendFormat": "PFCP Sessions"
        },
        {
          "datasource": "prometheus",
          "expr": "fivegs_smffunction_sm_sessionnbr{snssai=~\"1-.*\"}",
          "legendFormat": "eMBB Sessions"
        },
        {
          "datasource": "prometheus",
          "expr": "fivegs_smffunction_sm_sessionnbr{snssai=~\"2-.*\"}",
          "legendFormat": "URLLC Sessions"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "custom": { "lineWidth": 2, "fillOpacity": 10 },
          "color": { "mode": "palette-classic" }
        }
      }
    }
  ],
  "schemaVersion": 38,
  "version": 1
}

```

## grafana/dashboards/5g-network-slicing.json

```json
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "liveNow": true,
  "panels": [
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 0,
        "y": 0
      },
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "pluginVersion": "11.0.0",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "up{job=\"upf-embb\"}",
          "legendFormat": "UPF eMBB",
          "refId": "A"
        }
      ],
      "title": "UPF eMBB",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "thresholds"
          },
          "mappings": [],
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "red",
                "value": null
              },
              {
                "color": "green",
                "value": 1
              }
            ]
          },
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 4,
        "w": 6,
        "x": 6,
        "y": 0
      },
      "id": 2,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto",
        "wideLayout": true
      },
      "pluginVersion": "11.0.0",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "up{job=\"upf-urllc\"}",
          "legendFormat": "UPF uRLLC",
          "refId": "A"
        }
      ],
      "title": "UPF uRLLC",
      "type": "stat"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisBorderShow": false,
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "Mbps",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 18,
            "gradientMode": "opacity",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "insertNulls": false,
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "Mbits"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 0,
        "y": 4
      },
      "id": 3,
      "options": {
        "legend": {
          "calcs": [
            "lastNotNull",
            "max",
            "mean"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "rate(upf_embb_rx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
          "legendFormat": "eMBB RX",
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "rate(upf_embb_tx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
          "legendFormat": "eMBB TX",
          "refId": "B"
        }
      ],
      "title": "eMBB Throughput",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisBorderShow": false,
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "Mbps",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 18,
            "gradientMode": "opacity",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "insertNulls": false,
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "Mbits"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 12,
        "y": 4
      },
      "id": 4,
      "options": {
        "legend": {
          "calcs": [
            "lastNotNull",
            "max",
            "mean"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "rate(upf_urllc_rx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
          "legendFormat": "uRLLC RX",
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "rate(upf_urllc_tx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
          "legendFormat": "uRLLC TX",
          "refId": "B"
        }
      ],
      "title": "uRLLC Throughput",
      "type": "timeseries"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "axisBorderShow": false,
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "Mbps",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 12,
            "gradientMode": "opacity",
            "hideFrom": {
              "legend": false,
              "tooltip": false,
              "viz": false
            },
            "insertNulls": false,
            "lineInterpolation": "smooth",
            "lineWidth": 2,
            "pointSize": 5,
            "scaleDistribution": {
              "type": "linear"
            },
            "showPoints": "never",
            "spanNulls": true,
            "stacking": {
              "group": "A",
              "mode": "none"
            },
            "thresholdsStyle": {
              "mode": "off"
            }
          },
          "mappings": [],
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              }
            ]
          },
          "unit": "Mbits"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 9,
        "w": 24,
        "x": 0,
        "y": 13
      },
      "id": 5,
      "options": {
        "legend": {
          "calcs": [
            "lastNotNull",
            "max",
            "mean"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "rate(upf_embb_rx_bytes_total{job=\"upf-embb\"}[30s]) * 8 / 1000000",
          "legendFormat": "eMBB RX",
          "refId": "A"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "expr": "rate(upf_urllc_rx_bytes_total{job=\"upf-urllc\"}[30s]) * 8 / 1000000",
          "legendFormat": "uRLLC RX",
          "refId": "B"
        }
      ],
      "title": "Slice Comparison",
      "type": "timeseries"
    }
  ],
  "refresh": "15s",
  "schemaVersion": 39,
  "tags": [
    "5g",
    "network-slicing",
    "open5gs"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-15m",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "browser",
  "title": "5G Network Slicing",
  "uid": "5g-network-slicing",
  "version": 1,
  "weekStart": ""
}

```

## check-5g.sh

```bash
#!/bin/bash
set -u

OK=0
WARN=0
FAIL=0

pass() { printf "[PASS] %s\n" "$1"; OK=$((OK+1)); }
warn() { printf "[WARN] %s\n" "$1"; WARN=$((WARN+1)); }
fail() { printf "[FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); }

container_state() {
  docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true
}

need_running() {
  local name="$1"
  if [ "$(container_state "$name")" = "running" ]; then
    pass "$name is running"
  else
    fail "$name is not running"
  fi
}

optional_running() {
  local name="$1"
  if [ "$(container_state "$name")" = "running" ]; then
    pass "$name is running"
  else
    warn "$name is not running (optional profile)"
  fi
}

log_has() {
  local name="$1"
  local pattern="$2"
  docker logs "$name" --tail 300 2>&1 | grep -Eiq "$pattern"
}

check_tunnel() {
  local name="$1"
  local ip
  ip=$(docker exec "$name" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || true)
  if [ -n "$ip" ]; then
    pass "$name has uesimtun0: $ip"
  else
    fail "$name has no uesimtun0"
  fi
}

check_ping() {
  local name="$1"
  local target="$2"
  if docker exec "$name" ping -I uesimtun0 "$target" -c 2 -W 3 >/dev/null 2>&1; then
    pass "$name ping through uesimtun0 to $target"
  else
    warn "$name cannot ping $target through uesimtun0"
  fi
}

check_qos() {
  local upf="$1"
  if docker exec "$upf" tc qdisc show dev ogstun 2>/dev/null | grep -Eq 'htb|fq_codel|netem|tbf'; then
    pass "$upf has tc policy on ogstun"
  else
    warn "$upf has no tc policy on ogstun"
  fi
}

echo "== Docker =="
if docker ps >/dev/null 2>&1; then
  pass "docker ps works"
else
  fail "docker ps failed"
fi

if docker compose config >/dev/null 2>&1; then
  pass "docker compose config is valid"
else
  fail "docker compose config failed"
fi

echo
echo "== Core containers =="
for c in mongo nrf nssf amf ausf udm udr pcf smf upf-embb upf-urllc gnb ue-embb ue-urllc; do
  need_running "$c"
done

echo
echo "== MongoDB =="
mongo_health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' mongo 2>/dev/null || true)
if [ "$mongo_health" = "healthy" ]; then
  pass "mongo is healthy"
elif [ "$mongo_health" = "none" ] && [ "$(container_state mongo)" = "running" ]; then
  warn "mongo is running without health status"
else
  fail "mongo health is ${mongo_health:-unknown}"
fi

echo
echo "== Registration signals =="
if log_has amf 'gNB.*connected|NG setup|NGSetup|SCTP.*connected'; then
  pass "AMF log shows gNB connection"
else
  warn "AMF log does not show a clear gNB connection yet"
fi

if log_has gnb 'NG Setup|connected|Connection setup'; then
  pass "gNB log shows AMF connection"
else
  warn "gNB log does not show a clear AMF connection yet"
fi

for ue in ue-embb ue-urllc; do
  if log_has "$ue" 'Registration.*accepted|registered|PDU Session.*established|Session.*established'; then
    pass "$ue log shows registration/session progress"
  else
    warn "$ue log does not show registration/session progress yet"
  fi
done

if log_has smf 'PFCP.*associated|Session.*established|PDU Session|Created'; then
  pass "SMF log shows PFCP/PDU activity"
else
  warn "SMF log does not show PFCP/PDU activity yet"
fi

echo
echo "== UE tunnels =="
check_tunnel ue-embb
check_tunnel ue-urllc

echo
echo "== Slice connectivity =="
check_ping ue-embb 10.45.0.1
check_ping ue-urllc 10.46.0.1

echo
echo "== UPF QoS =="
check_qos upf-embb
check_qos upf-urllc

echo
echo "== Optional profiles =="
for c in prometheus grafana pushgateway node-exporter cadvisor embb-iperf-server urllc-iperf-server mqtt-server webui; do
  optional_running "$c"
done

echo
echo "Summary: $OK PASS, $WARN WARN, $FAIL FAIL"
[ "$FAIL" -eq 0 ]

```

## check-5g.ps1

```powershell
$OkCount = 0
$WarnCount = 0
$FailCount = 0

function Pass($Message) {
    Write-Host "[OK]   $Message"
    $script:OkCount++
}

function Warn($Message) {
    Write-Host "[WARN] $Message"
    $script:WarnCount++
}

function Fail($Message) {
    Write-Host "[FAIL] $Message"
    $script:FailCount++
}

function Need-Container($Name) {
    $state = docker inspect -f "{{.State.Status}}" $Name 2>$null
    if ($LASTEXITCODE -eq 0 -and $state -eq "running") {
        Pass "container $Name is running"
    } else {
        Fail "container $Name is not running"
    }
}

function Check-Tunnel($Name) {
    $ip = docker exec $Name sh -c "ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print `$2}'" 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ip)) {
        Pass "$Name tunnel uesimtun0: $ip"
    } else {
        Fail "$Name has no uesimtun0 tunnel"
    }
}

function Check-Ping($Name) {
    docker exec $Name ping -I uesimtun0 1.1.1.1 -c 2 -W 3 *> $null
    if ($LASTEXITCODE -eq 0) {
        Pass "$Name internet ping through 5G tunnel"
    } else {
        Warn "$Name cannot ping 1.1.1.1 through uesimtun0"
    }
}

function Check-Qos($Name) {
    $qdisc = docker exec $Name tc qdisc show dev ogstun 2>$null
    if ($LASTEXITCODE -eq 0 -and ($qdisc -match "htb|tbf|netem|fq_codel")) {
        Pass "$Name QoS qdisc is configured"
    } else {
        Warn "$Name QoS qdisc not found"
    }
}

Write-Host "== Docker compose syntax =="
docker compose config *> $null
if ($LASTEXITCODE -eq 0) {
    Pass "docker-compose.yaml is valid"
} else {
    Fail "docker-compose.yaml has an error"
}

Write-Host ""
Write-Host "== Containers =="
$containers = @(
    "mongo", "nrf", "amf", "smf", "ausf", "udm", "udr", "pcf",
    "upf-embb", "upf-urllc", "webui", "prometheus", "grafana",
    "gnb", "ue-embb", "ue-urllc", "pushgateway", "node-exporter", "cadvisor",
    "embb-iperf-server"
)
foreach ($container in $containers) {
    Need-Container $container
}

Write-Host ""
Write-Host "== UE tunnels =="
Check-Tunnel "ue-embb"
Check-Tunnel "ue-urllc"

Write-Host ""
Write-Host "== Slice connectivity =="
Check-Ping "ue-embb"
Check-Ping "ue-urllc"

Write-Host ""
Write-Host "== UPF QoS =="
Check-Qos "upf-embb"
Check-Qos "upf-urllc"

Write-Host ""
Write-Host "== Prometheus =="
docker exec prometheus wget -qO- http://localhost:9090/-/ready *> $null
if ($LASTEXITCODE -eq 0) {
    Pass "Prometheus is ready"
} else {
    Warn "Prometheus is not ready yet"
}

Write-Host ""
Write-Host "Summary: $OkCount ok, $WarnCount warning, $FailCount fail"
if ($FailCount -gt 0) {
    exit 1
}

```

## fix-upf.sh

```bash
#!/bin/bash
set -e

echo "=================================================="
echo "   5G Network Slicing - Fix UPF"
echo "   Open5GS v2.7.5 + Docker"
echo "=================================================="

apply_embb_qos() {
  if docker exec upf-embb test -f /scripts/apply-slice-qos.sh; then
    docker exec upf-embb /bin/bash /scripts/apply-slice-qos.sh embb ogstun >/dev/null
  else
    docker exec upf-embb tc qdisc del dev ogstun root 2>/dev/null || true
    docker exec upf-embb tc qdisc add dev ogstun root handle 1: htb default 10 r2q 1000
    docker exec upf-embb tc class add dev ogstun parent 1: classid 1:10 htb \
      rate 2mbit ceil 6mbit burst 128k cburst 128k prio 2
    docker exec upf-embb tc qdisc add dev ogstun parent 1:10 handle 10: netem \
      delay 6ms 1ms distribution normal loss 0% limit 256
    docker exec upf-embb tc qdisc add dev ogstun parent 10:1 handle 20: fq_codel \
      limit 512 target 5ms interval 100ms quantum 1514 ecn
  fi
}

apply_urllc_qos() {
  if docker exec upf-urllc test -f /scripts/apply-slice-qos.sh; then
    docker exec upf-urllc /bin/bash /scripts/apply-slice-qos.sh urllc ogstun >/dev/null
  else
    docker exec upf-urllc tc qdisc del dev ogstun root 2>/dev/null || true
    docker exec upf-urllc tc qdisc add dev ogstun root handle 1: htb default 10 r2q 1000
    docker exec upf-urllc tc class add dev ogstun parent 1: classid 1:10 htb \
      rate 3mbit ceil 7mbit burst 32k cburst 32k prio 0
    docker exec upf-urllc tc qdisc add dev ogstun parent 1:10 handle 10: netem \
      delay 1ms 0.1ms distribution normal loss 0.01% limit 8
    docker exec upf-urllc tc qdisc add dev ogstun parent 10:1 handle 20: fq_codel \
      limit 32 target 1ms interval 5ms quantum 300 ecn
  fi
}

echo ""
echo "[1/7] Fixing IP - UPF-eMBB (10.45.0.1/16)..."
docker exec upf-embb ip addr del 10.45.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-embb ip addr add 10.45.0.1/16 dev ogstun
docker exec upf-embb ip link set ogstun txqueuelen 10000
echo "      OK"

echo "[2/7] Fixing NAT - UPF-eMBB..."
docker exec upf-embb iptables -t nat -F POSTROUTING 2>/dev/null || true
docker exec upf-embb iptables -t nat -A POSTROUTING \
  -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE
echo "      OK"

echo "[3/7] Fixing QoS - UPF-eMBB (contention-safe profile: 2Mbps rate, 6Mbps ceiling)..."
apply_embb_qos
echo "      OK"

echo ""
echo "[4/7] Fixing IP - UPF-uRLLC (10.46.0.1/16)..."
docker exec upf-urllc ip addr del 10.46.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr del 10.45.0.1/16 dev ogstun 2>/dev/null || true
docker exec upf-urllc ip addr add 10.46.0.1/16 dev ogstun
docker exec upf-urllc ip link set ogstun txqueuelen 1000
echo "      OK"

echo "[5/7] Fixing NAT - UPF-uRLLC..."
docker exec upf-urllc iptables -t nat -F POSTROUTING 2>/dev/null || true
docker exec upf-urllc iptables -t nat -A POSTROUTING \
  -s 10.46.0.0/16 ! -o ogstun -j MASQUERADE
echo "      OK"

echo "[6/7] Fixing QoS - UPF-uRLLC (latency-first profile: 3Mbps rate, 7Mbps ceiling, short queue)..."
apply_urllc_qos
echo "      OK"

echo ""
echo "[7/7] Restarting UEs to refresh GTP-U sessions..."
docker compose restart ue-embb ue-urllc >/dev/null
sleep 15
echo "      OK"

echo ""
echo "=================================================="
echo "   VERIFY"
echo "=================================================="

echo ""
echo "--- IP ogstun ---"
echo -n "UPF-eMBB  : "
docker exec upf-embb ip addr show ogstun | awk '/inet / {print $2}'
echo -n "UPF-uRLLC : "
docker exec upf-urllc ip addr show ogstun | awk '/inet / {print $2}'

echo ""
echo "--- TC Rules ---"
echo -n "UPF-eMBB  : "
docker exec upf-embb tc qdisc show dev ogstun | grep -E "htb|netem|fq_codel" || echo "NOT FOUND"
echo -n "UPF-uRLLC : "
docker exec upf-urllc tc qdisc show dev ogstun | grep -E "htb|netem|fq_codel" || echo "NOT FOUND"

echo ""
echo "--- UE Tunnel IP ---"
echo -n "UE-eMBB  : "
docker exec ue-embb ip addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || echo "TUNNEL DOWN"
echo -n "UE-uRLLC : "
docker exec ue-urllc ip addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' || echo "TUNNEL DOWN"

echo ""
echo "--- Ping Test ---"
echo -n "UE-eMBB  -> 1.1.1.1 : "
docker exec ue-embb ping -I uesimtun0 1.1.1.1 -c 2 -W 3 -q 2>/dev/null \
  | grep "packet loss" | awk '{print $6" loss"}' || echo "FAIL"
echo -n "UE-uRLLC -> 1.1.1.1 : "
docker exec ue-urllc ping -I uesimtun0 1.1.1.1 -c 2 -W 3 -q 2>/dev/null \
  | grep "packet loss" | awk '{print $6" loss"}' || echo "FAIL"

echo ""
echo "DONE"

```

## run-5g-resource-optimization.sh

```bash
#!/bin/bash
set -euo pipefail

DURATION="${DURATION:-60}"
STABILITY_DURATION="${STABILITY_DURATION:-300}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-10}"
EMBB_PARALLEL="${EMBB_PARALLEL:-4}"
URLLC_TARGET="${URLLC_TARGET:-10.46.0.1}"
PING_COUNT="${PING_COUNT:-50}"
PING_INTERVAL="${PING_INTERVAL:-0.1}"
IPERF_IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
IPERF_SERVER="${IPERF_SERVER:-embb-iperf-server}"
IPERF_SERVER_IP="${IPERF_SERVER_IP:-172.20.0.221}"
IPERF_PORT="${IPERF_PORT:-5201}"
EMBB_CEIL_MBPS="${EMBB_CEIL_MBPS:-6}"
URLLC_RTT_SLA_MS="${URLLC_RTT_SLA_MS:-10}"
URLLC_JITTER_SLA_MS="${URLLC_JITTER_SLA_MS:-2}"
REPORT_DIR="${REPORT_DIR:-reports}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
REPORT_FILE="$REPORT_DIR/5g-resource-optimization-$RUN_ID.md"
CSV_FILE="$REPORT_DIR/5g-resource-optimization-$RUN_ID.csv"
STABILITY_CSV="$REPORT_DIR/5g-resource-optimization-stability-$RUN_ID.csv"
IPERF_CLIENT_NAME="embb-resource-load-$RUN_ID"

cleanup() {
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running. Start the lab with: docker compose up -d" >&2
        exit 1
    fi
}

ensure_iperf_server() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$IPERF_SERVER" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Starting $IPERF_SERVER..."
        docker compose up -d "$IPERF_SERVER" >/dev/null
    fi
}

ue_ip() {
    docker exec "$1" ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

upf_counter() {
    local upf="$1"
    local field="$2"
    docker exec "$upf" awk -v field="$field" '$1 ~ /ogstun:/ {print $field}' /proc/net/dev
}

measure_counter_mbps() {
    local upf="$1"
    local field="$2"
    local seconds="$3"
    local before after
    before=$(upf_counter "$upf" "$field")
    sleep "$seconds"
    after=$(upf_counter "$upf" "$field")
    awk -v before="$before" -v after="$after" -v seconds="$seconds" \
        'BEGIN {printf "%.2f", (after - before) * 8 / seconds / 1000000}'
}

parse_ping() {
    awk '
      /packet loss/ {
        split($0, parts, ",")
        loss = parts[3]
        gsub(/^ +| +$/, "", loss)
      }
      /rtt|round-trip/ {
        split($0, fields, "=")
        split(fields[2], stats, "/")
        min = stats[1] + 0
        avg = stats[2] + 0
        max = stats[3] + 0
        mdev = stats[4] + 0
        seen_rtt = 1
      }
      END {
        if (!seen_rtt) {
          printf "timeout,timeout,timeout,timeout,%s", (loss == "" ? "100% packet loss" : loss)
        } else {
          printf "%.3f,%.3f,%.3f,%.3f,%s", min, avg, max, mdev, loss
        }
      }'
}

ping_urllc() {
    local output
    output=$(docker exec ue-urllc ping -I uesimtun0 "$URLLC_TARGET" -c "$PING_COUNT" -i "$PING_INTERVAL" -q 2>/dev/null || true)
    printf "%s\n" "$output" | parse_ping
}

field() {
    echo "$1" | awk -F, -v idx="$2" '{print $idx}'
}

ratio() {
    awk -v base="$1" -v load="$2" 'BEGIN {
      if (base == "timeout" || load == "timeout" || base <= 0) print "n/a";
      else printf "%.2f", load / base
    }'
}

percent() {
    awk -v value="$1" -v total="$2" 'BEGIN {
      if (value == "timeout" || total <= 0) print "n/a";
      else printf "%.1f", value / total * 100
    }'
}

sla_status() {
    awk -v avg="$1" -v jitter="$2" -v rtt_sla="$URLLC_RTT_SLA_MS" -v jitter_sla="$URLLC_JITTER_SLA_MS" 'BEGIN {
      if (avg == "timeout" || jitter == "timeout") print "FAIL";
      else if (avg <= rtt_sla && jitter <= jitter_sla) print "PASS";
      else print "FAIL";
    }'
}

start_embb_download() {
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
    docker run -d --rm \
        --name "$IPERF_CLIENT_NAME" \
        --network container:ue-embb \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" -R \
        -B "$EMBB_IP" -P "$EMBB_PARALLEL" -t "$1" \
        >/dev/null
}

stop_embb_download() {
    docker rm -f "$IPERF_CLIENT_NAME" >/dev/null 2>&1 || true
}

echo "============================================================"
echo "  5G network slicing resource optimization benchmark"
echo "============================================================"
echo

ensure_iperf_server
for c in upf-embb upf-urllc ue-embb ue-urllc "$IPERF_SERVER"; do
    need_container "$c"
done

echo "[1/6] Applying scaled resource profiles"
bash ./fix-upf.sh >/dev/null 2>&1
echo "      eMBB : 2 Mbps guaranteed, 6 Mbps ceiling"
echo "      URLLC: 3 Mbps guaranteed, 7 Mbps ceiling, very short queue"

EMBB_IP=$(ue_ip ue-embb)
URLLC_IP=$(ue_ip ue-urllc)
if [ -z "$EMBB_IP" ] || [ -z "$URLLC_IP" ]; then
    echo "One UE tunnel is missing. Run: bash ./check-5g.sh" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR"

echo
echo "[2/6] Preflight"
echo "      eMBB UE : $EMBB_IP"
echo "      URLLC UE: $URLLC_IP"
echo "      eMBB server: ${IPERF_SERVER_IP}:${IPERF_PORT}"
echo "      URLLC target: $URLLC_TARGET"
echo "      eMBB parallel flows: $EMBB_PARALLEL"
echo
docker exec ue-embb ip route get "$IPERF_SERVER_IP" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true

echo
echo "[3/6] Scenario A - URLLC idle SLA"
IDLE_CSV=$(ping_urllc)
IDLE_AVG=$(field "$IDLE_CSV" 2)
IDLE_JITTER=$(field "$IDLE_CSV" 4)
IDLE_LOSS=$(field "$IDLE_CSV" 5)
IDLE_SLA=$(sla_status "$IDLE_AVG" "$IDLE_JITTER")
echo "      avg=$IDLE_AVG ms, jitter=$IDLE_JITTER ms, loss=$IDLE_LOSS, SLA=$IDLE_SLA"

echo
echo "[4/6] Scenario B - eMBB-only throughput under scaled ceiling"
start_embb_download "$((DURATION + 5))"
sleep 3
EMBB_ONLY_MBPS=$(measure_counter_mbps upf-embb 10 "$DURATION")
stop_embb_download
EMBB_ONLY_EFF=$(percent "$EMBB_ONLY_MBPS" "$EMBB_CEIL_MBPS")
echo "      eMBB downlink=$EMBB_ONLY_MBPS Mbps, allocation efficiency=${EMBB_ONLY_EFF}%"

echo
echo "[5/6] Scenario C - URLLC SLA while eMBB is saturated"
start_embb_download "$((DURATION + 20))"
sleep 3
LOAD_EMBB_MBPS=$(measure_counter_mbps upf-embb 10 "$DURATION")
LOAD_CSV=$(ping_urllc)
stop_embb_download
LOAD_AVG=$(field "$LOAD_CSV" 2)
LOAD_JITTER=$(field "$LOAD_CSV" 4)
LOAD_LOSS=$(field "$LOAD_CSV" 5)
LATENCY_RATIO=$(ratio "$IDLE_AVG" "$LOAD_AVG")
JITTER_RATIO=$(ratio "$IDLE_JITTER" "$LOAD_JITTER")
LOAD_SLA=$(sla_status "$LOAD_AVG" "$LOAD_JITTER")
LOAD_EMBB_EFF=$(percent "$LOAD_EMBB_MBPS" "$EMBB_CEIL_MBPS")
echo "      eMBB downlink=$LOAD_EMBB_MBPS Mbps"
echo "      eMBB allocation efficiency=${LOAD_EMBB_EFF}% of ${EMBB_CEIL_MBPS} Mbps ceiling"
echo "      URLLC avg=$LOAD_AVG ms, jitter=$LOAD_JITTER ms, loss=$LOAD_LOSS, SLA=$LOAD_SLA"
echo "      isolation ratios: latency=$LATENCY_RATIO, jitter=$JITTER_RATIO"

echo
echo "[6/6] Scenario D - sustained stability"
echo "sample,elapsed_s,embb_downlink_mbps,urllc_avg_ms,urllc_jitter_ms,urllc_loss" > "$STABILITY_CSV"
start_embb_download "$((STABILITY_DURATION + 30))"
END=$((SECONDS + STABILITY_DURATION))
SAMPLE=0
while [ "$SECONDS" -lt "$END" ]; do
    SAMPLE=$((SAMPLE + 1))
    BEFORE=$(upf_counter upf-embb 10)
    sleep "$SAMPLE_INTERVAL"
    AFTER=$(upf_counter upf-embb 10)
    SHORT_PING=$(docker exec ue-urllc ping -I uesimtun0 "$URLLC_TARGET" -c 5 -i 0.2 -q 2>/dev/null || true)
    SAMPLE_MBPS=$(awk -v before="$BEFORE" -v after="$AFTER" -v seconds="$SAMPLE_INTERVAL" \
        'BEGIN {printf "%.2f", (after - before) * 8 / seconds / 1000000}')
    SAMPLE_CSV=$(printf "%s\n" "$SHORT_PING" | parse_ping)
    SAMPLE_AVG=$(field "$SAMPLE_CSV" 2)
    SAMPLE_JITTER=$(field "$SAMPLE_CSV" 4)
    SAMPLE_LOSS=$(field "$SAMPLE_CSV" 5)
    ELAPSED=$((SAMPLE * SAMPLE_INTERVAL))
    echo "$SAMPLE,$ELAPSED,$SAMPLE_MBPS,$SAMPLE_AVG,$SAMPLE_JITTER,$SAMPLE_LOSS" >> "$STABILITY_CSV"
    printf "      %4ss  eMBB=%s Mbps  URLLC avg=%s ms jitter=%s ms loss=%s\n" \
        "$ELAPSED" "$SAMPLE_MBPS" "$SAMPLE_AVG" "$SAMPLE_JITTER" "$SAMPLE_LOSS"
done
stop_embb_download

cat > "$REPORT_FILE" <<EOF_REPORT
# 5G Network Slicing Resource Optimization Benchmark

Run ID: $RUN_ID

## Testbed Scope

This benchmark uses a scaled resource profile because the Open5GS userspace UPF throughput ceiling in this VM is lower than a real 5G data plane. The goal is to validate slice resource behavior: eMBB gets sustained broadband capacity, while uRLLC keeps latency and jitter stable under eMBB saturation.

## Configuration

- eMBB UE IP: $EMBB_IP
- uRLLC UE IP: $URLLC_IP
- eMBB generator: iperf3 reverse TCP, ${IPERF_SERVER_IP}:${IPERF_PORT}
- eMBB parallel flows: $EMBB_PARALLEL
- uRLLC latency target: $URLLC_TARGET
- eMBB profile: 2 Mbps guaranteed, 6 Mbps ceiling
- uRLLC profile: 3 Mbps guaranteed, 7 Mbps ceiling, fq_codel very short queue
- uRLLC SLA target: avg RTT <= ${URLLC_RTT_SLA_MS} ms, jitter <= ${URLLC_JITTER_SLA_MS} ms

## Results

| Scenario | Metric | Result |
| --- | --- | ---: |
| uRLLC idle | avg RTT | $IDLE_AVG ms |
| uRLLC idle | jitter/mdev | $IDLE_JITTER ms |
| uRLLC idle | packet loss | $IDLE_LOSS |
| uRLLC idle | SLA status | $IDLE_SLA |
| eMBB only | downlink throughput | $EMBB_ONLY_MBPS Mbps |
| eMBB only | allocation efficiency | ${EMBB_ONLY_EFF}% |
| eMBB + uRLLC | eMBB downlink throughput | $LOAD_EMBB_MBPS Mbps |
| eMBB + uRLLC | eMBB allocation efficiency | ${LOAD_EMBB_EFF}% |
| eMBB + uRLLC | uRLLC avg RTT | $LOAD_AVG ms |
| eMBB + uRLLC | uRLLC jitter/mdev | $LOAD_JITTER ms |
| eMBB + uRLLC | uRLLC packet loss | $LOAD_LOSS |
| eMBB + uRLLC | uRLLC SLA status | $LOAD_SLA |

## Isolation Indicators

- Latency isolation ratio, load / idle: $LATENCY_RATIO
- Jitter isolation ratio, load / idle: $JITTER_RATIO

## Interpretation

A ratio close to 1.00 means uRLLC remains stable while eMBB consumes its allocated broadband slice. The eMBB ceiling is intentionally set below the measured downlink tunnel ceiling so HTB enforces a real resource policy. The optimization target is SLA stability plus high allocation efficiency within the testbed's real forwarding capacity, not a hardware-grade 5G throughput claim.

Stability samples: $STABILITY_CSV
EOF_REPORT

cat > "$CSV_FILE" <<EOF_CSV
run_id,embb_ceil_mbps,embb_only_mbps,embb_load_mbps,embb_only_efficiency_pct,embb_load_efficiency_pct,urllc_idle_avg_ms,urllc_load_avg_ms,urllc_idle_jitter_ms,urllc_load_jitter_ms,urllc_idle_loss,urllc_load_loss,urllc_idle_sla,urllc_load_sla,latency_ratio,jitter_ratio
$RUN_ID,$EMBB_CEIL_MBPS,$EMBB_ONLY_MBPS,$LOAD_EMBB_MBPS,$EMBB_ONLY_EFF,$LOAD_EMBB_EFF,$IDLE_AVG,$LOAD_AVG,$IDLE_JITTER,$LOAD_JITTER,$IDLE_LOSS,$LOAD_LOSS,$IDLE_SLA,$LOAD_SLA,$LATENCY_RATIO,$JITTER_RATIO
EOF_CSV

echo
echo "Report: $REPORT_FILE"
echo "CSV   : $CSV_FILE"
echo "Series: $STABILITY_CSV"

```

## scripts/apply-slice-qos.sh

```bash
#!/bin/bash
set -euo pipefail

SLICE="${1:-}"
DEV="${2:-ogstun}"
EMBB_RATE="${EMBB_RATE:-2mbit}"
EMBB_CEIL="${EMBB_CEIL:-6mbit}"
EMBB_BURST="${EMBB_BURST:-128k}"
EMBB_CBURST="${EMBB_CBURST:-128k}"
EMBB_DELAY="${EMBB_DELAY:-6ms}"
EMBB_JITTER="${EMBB_JITTER:-1ms}"
EMBB_LOSS="${EMBB_LOSS:-0%}"
EMBB_LIMIT="${EMBB_LIMIT:-256}"
EMBB_FQ_CODEL_LIMIT="${EMBB_FQ_CODEL_LIMIT:-512}"
EMBB_FQ_CODEL_TARGET="${EMBB_FQ_CODEL_TARGET:-5ms}"
EMBB_FQ_CODEL_INTERVAL="${EMBB_FQ_CODEL_INTERVAL:-100ms}"
URLLC_RATE="${URLLC_RATE:-3mbit}"
URLLC_CEIL="${URLLC_CEIL:-7mbit}"
URLLC_BURST="${URLLC_BURST:-32k}"
URLLC_CBURST="${URLLC_CBURST:-32k}"
URLLC_DELAY="${URLLC_DELAY:-1ms}"
URLLC_JITTER="${URLLC_JITTER:-0.1ms}"
URLLC_LOSS="${URLLC_LOSS:-0.01%}"
URLLC_LIMIT="${URLLC_LIMIT:-8}"
URLLC_FQ_CODEL_LIMIT="${URLLC_FQ_CODEL_LIMIT:-32}"
URLLC_FQ_CODEL_TARGET="${URLLC_FQ_CODEL_TARGET:-1ms}"
URLLC_FQ_CODEL_INTERVAL="${URLLC_FQ_CODEL_INTERVAL:-5ms}"

usage() {
    echo "Usage: $0 <embb|urllc> [device]" >&2
    exit 2
}

[ -n "$SLICE" ] || usage

tc qdisc del dev "$DEV" root 2>/dev/null || true

case "$SLICE" in
    embb)
        # eMBB favors large sustained throughput. The added delay/jitter keeps
        # the lab closer to a loaded mobile broadband path than a LAN link.
        tc qdisc add dev "$DEV" root handle 1: htb default 10 r2q 1000
        tc class add dev "$DEV" parent 1: classid 1:10 htb \
            rate "$EMBB_RATE" ceil "$EMBB_CEIL" \
            burst "$EMBB_BURST" cburst "$EMBB_CBURST" prio 2
        tc qdisc add dev "$DEV" parent 1:10 handle 10: netem \
            delay "$EMBB_DELAY" "$EMBB_JITTER" distribution normal \
            loss "$EMBB_LOSS" limit "$EMBB_LIMIT"
        tc qdisc add dev "$DEV" parent 10:1 handle 20: fq_codel \
            limit "$EMBB_FQ_CODEL_LIMIT" target "$EMBB_FQ_CODEL_TARGET" \
            interval "$EMBB_FQ_CODEL_INTERVAL" quantum 1514 ecn
        ;;
    urllc)
        # URLLC trades peak throughput for low delay, low jitter, and smaller
        # queues so latency does not grow too much under short bursts. netem
        # models radio delay; fq_codel keeps the remaining queue short.
        tc qdisc add dev "$DEV" root handle 1: htb default 10 r2q 1000
        tc class add dev "$DEV" parent 1: classid 1:10 htb \
            rate "$URLLC_RATE" ceil "$URLLC_CEIL" \
            burst "$URLLC_BURST" cburst "$URLLC_CBURST" prio 0
        tc qdisc add dev "$DEV" parent 1:10 handle 10: netem \
            delay "$URLLC_DELAY" "$URLLC_JITTER" distribution normal \
            loss "$URLLC_LOSS" limit "$URLLC_LIMIT"
        tc qdisc add dev "$DEV" parent 10:1 handle 20: fq_codel \
            limit "$URLLC_FQ_CODEL_LIMIT" target "$URLLC_FQ_CODEL_TARGET" \
            interval "$URLLC_FQ_CODEL_INTERVAL" quantum 300 ecn
        ;;
    *)
        usage
        ;;
esac

echo "Applied $SLICE QoS on $DEV"
tc qdisc show dev "$DEV"

```

## scripts/debug-embb-throughput.sh

```bash
#!/bin/bash
set -euo pipefail

IPERF_IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
IPERF_SERVER="${IPERF_SERVER:-embb-iperf-server}"
IPERF_SERVER_IP="${IPERF_SERVER_IP:-172.20.0.221}"
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-20}"
WARMUP="${WARMUP:-3}"
FLOWS="${FLOWS:-1 2 4 8}"
CLIENT_PREFIX="embb-iperf-debug-$$"
UPLOAD_RESULTS=()
DOWNLOAD_RESULTS=()

cleanup() {
    docker rm -f "${CLIENT_PREFIX}-bridge" "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running." >&2
        exit 1
    fi
}

ensure_iperf_server() {
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$IPERF_SERVER" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Starting $IPERF_SERVER..."
        docker compose up -d "$IPERF_SERVER" >/dev/null
    fi
}

ue_ip() {
    docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1
}

ogstun_bytes() {
    local direction="$1"
    docker exec upf-embb awk -v direction="$direction" '
      $1 ~ /ogstun:/ {
        gsub(/:/, "", $1)
        if (direction == "rx") print $2
        if (direction == "tx") print $10
      }' /proc/net/dev
}

iperf_mbps() {
    awk '
      /receiver/ && /bits\/sec/ {
        value = $(NF - 2)
        unit = $(NF - 1)
        if (unit == "Kbits/sec") value = value / 1000
        if (unit == "Gbits/sec") value = value * 1000
        last = value
      }
      END {
        if (last == "") print "n/a";
        else printf "%.2f", last
      }'
}

run_bridge_baseline() {
    local network="$1"
    local flows="$2"
    docker rm -f "${CLIENT_PREFIX}-bridge" >/dev/null 2>&1 || true
    docker run --rm \
        --name "${CLIENT_PREFIX}-bridge" \
        --network "$network" \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" -t "$DURATION" -P "$flows" 2>&1
}

run_tunnel_test() {
    local flows="$1"
    local mode="$2"
    local before after output mbps tunnel_mbps counter_name real_duration
    local reverse_arg=()

    if [ "$mode" = "download" ]; then
        reverse_arg=(-R)
        counter_name="tx"
    else
        counter_name="rx"
    fi
    real_duration=$((DURATION - WARMUP))
    if [ "$real_duration" -lt 5 ]; then
        real_duration="$DURATION"
    fi

    docker rm -f "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
    if [ "$WARMUP" -gt 0 ] && [ "$real_duration" -ne "$DURATION" ]; then
        docker run --rm \
            --name "${CLIENT_PREFIX}-ue" \
            --network container:ue-embb \
            "$IPERF_IMAGE" \
            -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" \
            "${reverse_arg[@]}" \
            -B "$EMBB_IP" -t "$WARMUP" -P "$flows" >/dev/null 2>&1 || true
    fi

    before=$(ogstun_bytes "$counter_name")
    docker rm -f "${CLIENT_PREFIX}-ue" >/dev/null 2>&1 || true
    output=$(docker run --rm \
        --name "${CLIENT_PREFIX}-ue" \
        --network container:ue-embb \
        "$IPERF_IMAGE" \
        -c "$IPERF_SERVER_IP" -p "$IPERF_PORT" \
        "${reverse_arg[@]}" \
        -B "$EMBB_IP" -t "$real_duration" -P "$flows" 2>&1 || true)
    after=$(ogstun_bytes "$counter_name")

    mbps=$(printf "%s\n" "$output" | iperf_mbps)
    tunnel_mbps=$(awk -v before="$before" -v after="$after" -v seconds="$DURATION" \
        -v real_duration="$real_duration" \
        'BEGIN {printf "%.2f", (after - before) * 8 / real_duration / 1000000}')

    if [ "$mode" = "download" ] && [ "$tunnel_mbps" != "n/a" ]; then
        DOWNLOAD_RESULTS+=("$tunnel_mbps")
    elif [ "$mode" = "upload" ] && [ "$tunnel_mbps" != "n/a" ]; then
        UPLOAD_RESULTS+=("$tunnel_mbps")
    fi

    printf "%-12s %-6s %-14s %-14s %-10s\n" "$mode" "$flows" "$mbps" "$tunnel_mbps" "$counter_name"
}

max_result() {
    printf "%s\n" "$@" | awk '
      $1 ~ /^[0-9.]+$/ && $1 > max {max = $1}
      END {
        if (max == "") print "n/a";
        else printf "%.2f", max
      }'
}

echo "============================================================"
echo "  eMBB throughput debug"
echo "============================================================"
echo

ensure_iperf_server
for c in upf-embb ue-embb "$IPERF_SERVER"; do
    need_container "$c"
done

EMBB_IP=$(ue_ip)
CORE_NETWORK=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$IPERF_SERVER")
if [ -z "$EMBB_IP" ]; then
    echo "ue-embb has no uesimtun0 IP. Run: bash ./fix-upf.sh" >&2
    exit 1
fi
if [ -z "$CORE_NETWORK" ]; then
    echo "Could not detect Docker network for $IPERF_SERVER." >&2
    exit 1
fi

echo "Server     : $IPERF_SERVER_IP:$IPERF_PORT"
echo "UE eMBB IP : $EMBB_IP"
echo "Core net   : $CORE_NETWORK"
echo "Duration   : ${DURATION}s"
echo "Warm-up    : ${WARMUP}s per tunnel test"
echo
echo "Route from ue-embb to server through uesimtun0:"
docker exec ue-embb ip route get "$IPERF_SERVER_IP" oif uesimtun0 from "$EMBB_IP" 2>/dev/null || true
echo "Route selected by source IP without forcing oif:"
docker exec ue-embb ip route get "$IPERF_SERVER_IP" from "$EMBB_IP" 2>/dev/null || true
echo

echo "[1] Docker bridge baseline, not forced through 5G tunnel"
for flows in $FLOWS; do
    result=$(run_bridge_baseline "$CORE_NETWORK" "$flows" | iperf_mbps)
    printf "bridge       %-6s %-14s %-14s\n" "$flows" "$result" "n/a"
done

echo
echo "[2] 5G tunnel tests"
printf "%-12s %-6s %-14s %-14s %-10s\n" "mode" "flows" "iperf_mbps" "ogstun_mbps" "counter"
for flows in $FLOWS; do
    run_tunnel_test "$flows" "upload"
    run_tunnel_test "$flows" "download"
done

echo
UPLOAD_MAX=$(max_result "${UPLOAD_RESULTS[@]}")
DOWNLOAD_MAX=$(max_result "${DOWNLOAD_RESULTS[@]}")
RECOMMENDED_PARENT=$(awk -v up="$UPLOAD_MAX" -v down="$DOWNLOAD_MAX" 'BEGIN {
  if (up == "n/a" || down == "n/a") print "n/a";
  else {
    ceiling = (up < down ? up : down) * 0.8;
    if (ceiling < 5) ceiling = 5;
    printf "%.0fmbit", ceiling;
  }
}')
ASYMMETRY=$(awk -v up="$UPLOAD_MAX" -v down="$DOWNLOAD_MAX" 'BEGIN {
  if (up == "n/a" || down == "n/a" || down <= 0) print "n/a";
  else printf "%.2fx", up / down;
}')

echo
echo "============================================================"
echo "  Summary - measured tunnel ceiling"
echo "============================================================"
echo "Upload ceiling   : $UPLOAD_MAX Mbps"
echo "Download ceiling : $DOWNLOAD_MAX Mbps"
echo "UL/DL asymmetry  : $ASYMMETRY"
echo "Suggested parent : $RECOMMENDED_PARENT"
echo "                  Use the lower stable tunnel direction, not bridge speed."
echo
echo "Interpretation:"
echo "- bridge high, tunnel low: bottleneck is UPF/GTP/VM CPU, not iperf3."
echo "- upload high, download low: reverse/downlink path or UPF TX queue is the bottleneck."
echo "- throughput drops as flows increase: parallel TCP is overloading the userspace GTP path."
echo "- reverse download drops with many flows: TCP ACK/uplink feedback can double the GTP scheduling pressure."
echo "- upload uses ogstun RX and download uses ogstun TX; compare each mode with its matching counter."
echo "- iperf_mbps and ogstun_mbps should be close; if not, the traffic is not fully on the tunnel path."

```

## scripts/push-metrics.sh

```bash
#!/bin/bash
set -eu

PUSHGW="${PUSHGW:-http://localhost:9091}"
INTERVAL="${INTERVAL:-15}"

while true; do
    EMBB_RX=$(docker exec upf-embb awk '$1 ~ /ogstun:/ {print $2}' /proc/net/dev)
    EMBB_TX=$(docker exec upf-embb awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev)
    URLLC_RX=$(docker exec upf-urllc awk '$1 ~ /ogstun:/ {print $2}' /proc/net/dev)
    URLLC_TX=$(docker exec upf-urllc awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev)

    printf '%s\n' \
      '# HELP upf_embb_rx_bytes_total eMBB UPF received bytes on ogstun' \
      '# TYPE upf_embb_rx_bytes_total counter' \
      "upf_embb_rx_bytes_total ${EMBB_RX:-0}" \
      '# HELP upf_embb_tx_bytes_total eMBB UPF transmitted bytes on ogstun' \
      '# TYPE upf_embb_tx_bytes_total counter' \
      "upf_embb_tx_bytes_total ${EMBB_TX:-0}" \
      '# HELP upf_ogstun_rx_bytes_total UPF received bytes on ogstun' \
      '# TYPE upf_ogstun_rx_bytes_total counter' \
      "upf_ogstun_rx_bytes_total{slice=\"embb\",upf=\"upf-embb\"} ${EMBB_RX:-0}" \
      '# HELP upf_ogstun_tx_bytes_total UPF transmitted bytes on ogstun' \
      '# TYPE upf_ogstun_tx_bytes_total counter' \
      "upf_ogstun_tx_bytes_total{slice=\"embb\",upf=\"upf-embb\"} ${EMBB_TX:-0}" \
      | curl -fsS --data-binary @- "$PUSHGW/metrics/job/upf-embb" >/dev/null

    printf '%s\n' \
      '# HELP upf_urllc_rx_bytes_total URLLC UPF received bytes on ogstun' \
      '# TYPE upf_urllc_rx_bytes_total counter' \
      "upf_urllc_rx_bytes_total ${URLLC_RX:-0}" \
      '# HELP upf_urllc_tx_bytes_total URLLC UPF transmitted bytes on ogstun' \
      '# TYPE upf_urllc_tx_bytes_total counter' \
      "upf_urllc_tx_bytes_total ${URLLC_TX:-0}" \
      '# HELP upf_ogstun_rx_bytes_total UPF received bytes on ogstun' \
      '# TYPE upf_ogstun_rx_bytes_total counter' \
      "upf_ogstun_rx_bytes_total{slice=\"urllc\",upf=\"upf-urllc\"} ${URLLC_RX:-0}" \
      '# HELP upf_ogstun_tx_bytes_total UPF transmitted bytes on ogstun' \
      '# TYPE upf_ogstun_tx_bytes_total counter' \
      "upf_ogstun_tx_bytes_total{slice=\"urllc\",upf=\"upf-urllc\"} ${URLLC_TX:-0}" \
      | curl -fsS --data-binary @- "$PUSHGW/metrics/job/upf-urllc" >/dev/null

    sleep "$INTERVAL"
done

```

## scripts/test-embb.sh

```bash
#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
SERVER="${EMBB_SERVER_IP:-172.20.0.221}"
PORT="${EMBB_PORT:-5201}"
DURATION="${DURATION:-30}"
PARALLEL="${PARALLEL:-4}"

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

docker compose --profile traffic up -d embb-iperf-server >/dev/null
need_container ue-embb
need_container embb-iperf-server

UE_IP=$(docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$UE_IP" ]; then
    echo "ue-embb has no uesimtun0 address" >&2
    exit 1
fi

docker exec ue-embb ip route replace "$SERVER/32" dev uesimtun0 src "$UE_IP" 2>/dev/null || true

echo "eMBB TCP throughput test"
echo "UE=$UE_IP server=$SERVER:$PORT duration=${DURATION}s parallel=$PARALLEL"
docker run --rm \
    --network container:ue-embb \
    "$IMAGE" \
    -c "$SERVER" -p "$PORT" -B "$UE_IP" -P "$PARALLEL" -t "$DURATION"

```

## scripts/test-urllc.sh

```bash
#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
SERVER="${URLLC_SERVER_IP:-172.20.0.222}"
PORT="${URLLC_PORT:-5202}"
DURATION="${DURATION:-30}"
BITRATE="${URLLC_BITRATE:-1M}"
PACKET_SIZE="${URLLC_PACKET_SIZE:-120}"

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

docker compose --profile traffic up -d urllc-iperf-server >/dev/null
need_container ue-urllc
need_container urllc-iperf-server

UE_IP=$(docker exec ue-urllc ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$UE_IP" ]; then
    echo "ue-urllc has no uesimtun0 address" >&2
    exit 1
fi

docker exec ue-urllc ip route replace "$SERVER/32" dev uesimtun0 src "$UE_IP" 2>/dev/null || true

echo "URLLC UDP small-packet test"
echo "UE=$UE_IP server=$SERVER:$PORT duration=${DURATION}s bitrate=$BITRATE packet=${PACKET_SIZE}B"
docker run --rm \
    --network container:ue-urllc \
    "$IMAGE" \
    -c "$SERVER" -p "$PORT" -B "$UE_IP" -u -b "$BITRATE" -l "$PACKET_SIZE" -t "$DURATION"

```

## scripts/test-mixed.sh

```bash
#!/bin/bash
set -euo pipefail

IMAGE="${IPERF_IMAGE:-networkstatic/iperf3:latest}"
EMBB_SERVER="${EMBB_SERVER_IP:-172.20.0.221}"
EMBB_PORT="${EMBB_PORT:-5201}"
URLLC_SERVER="${URLLC_SERVER_IP:-172.20.0.222}"
URLLC_PORT="${URLLC_PORT:-5202}"
DURATION="${DURATION:-45}"
EMBB_PARALLEL="${EMBB_PARALLEL:-6}"
URLLC_BITRATE="${URLLC_BITRATE:-1M}"
URLLC_PACKET_SIZE="${URLLC_PACKET_SIZE:-120}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
EMBB_CLIENT="mixed-embb-load-$RUN_ID"

cleanup() {
    docker rm -f "$EMBB_CLIENT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

need_container() {
    local name="$1"
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    if [ "$state" != "running" ]; then
        echo "Container $name is not running" >&2
        exit 1
    fi
}

docker compose --profile traffic up -d embb-iperf-server urllc-iperf-server >/dev/null
for c in ue-embb ue-urllc embb-iperf-server urllc-iperf-server; do
    need_container "$c"
done

EMBB_IP=$(docker exec ue-embb ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
URLLC_IP=$(docker exec ue-urllc ip -4 addr show uesimtun0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)
if [ -z "$EMBB_IP" ] || [ -z "$URLLC_IP" ]; then
    echo "One UE tunnel is missing" >&2
    exit 1
fi

docker exec ue-embb ip route replace "$EMBB_SERVER/32" dev uesimtun0 src "$EMBB_IP" 2>/dev/null || true
docker exec ue-urllc ip route replace "$URLLC_SERVER/32" dev uesimtun0 src "$URLLC_IP" 2>/dev/null || true

echo "Mixed test: saturate eMBB while measuring URLLC UDP"
echo "eMBB UE=$EMBB_IP server=$EMBB_SERVER:$EMBB_PORT parallel=$EMBB_PARALLEL"
echo "URLLC UE=$URLLC_IP server=$URLLC_SERVER:$URLLC_PORT bitrate=$URLLC_BITRATE packet=${URLLC_PACKET_SIZE}B"

docker run -d --rm \
    --name "$EMBB_CLIENT" \
    --network container:ue-embb \
    "$IMAGE" \
    -c "$EMBB_SERVER" -p "$EMBB_PORT" -B "$EMBB_IP" -P "$EMBB_PARALLEL" -t "$DURATION" \
    >/dev/null

sleep 3
docker run --rm \
    --network container:ue-urllc \
    "$IMAGE" \
    -c "$URLLC_SERVER" -p "$URLLC_PORT" -B "$URLLC_IP" -u -b "$URLLC_BITRATE" -l "$URLLC_PACKET_SIZE" -t "$((DURATION - 5))"

```

## scripts/upf-embb-start.sh

```bash
#!/bin/bash
set -eo pipefail

# Create ogstun.
if ! grep "ogstun" /proc/net/dev > /dev/null; then
    echo "Creating ogstun device"
    ip tuntap add name ogstun mode tun
fi

ip addr del "$IPV4_TUN_ADDR" dev ogstun 2>/dev/null || true
ip addr add "$IPV4_TUN_ADDR" dev ogstun
sysctl -w net.ipv6.conf.all.disable_ipv6=0
ip addr del "$IPV6_TUN_ADDR" dev ogstun 2>/dev/null || true
ip addr add "$IPV6_TUN_ADDR" dev ogstun
ip link set ogstun up
ip link set ogstun txqueuelen "${OGSTUN_TXQUEUELEN:-10000}"

echo 1 > /proc/sys/net/ipv4/ip_forward
if [ "$ENABLE_NAT" = true ]; then
    iptables -t nat -A POSTROUTING -s "$IPV4_TUN_SUBNET" ! -o ogstun -j MASQUERADE
fi

echo "Applying eMBB QoS rules..."
/bin/bash /scripts/apply-slice-qos.sh embb ogstun

sleep 10
exec open5gs-upfd -c /opt/open5gs/etc/open5gs/upf-embb.yaml

```

## scripts/upf-urllc-start.sh

```bash
#!/bin/bash
set -eo pipefail

# Create ogstun.
if ! grep "ogstun" /proc/net/dev > /dev/null; then
    echo "Creating ogstun device"
    ip tuntap add name ogstun mode tun
fi

ip addr del "$IPV4_TUN_ADDR" dev ogstun 2>/dev/null || true
ip addr add "$IPV4_TUN_ADDR" dev ogstun
sysctl -w net.ipv6.conf.all.disable_ipv6=0
ip addr del "$IPV6_TUN_ADDR" dev ogstun 2>/dev/null || true
ip addr add "$IPV6_TUN_ADDR" dev ogstun
ip link set ogstun up
ip link set ogstun txqueuelen "${OGSTUN_TXQUEUELEN:-1000}"

echo 1 > /proc/sys/net/ipv4/ip_forward
if [ "$ENABLE_NAT" = true ]; then
    iptables -t nat -A POSTROUTING -s "$IPV4_TUN_SUBNET" ! -o ogstun -j MASQUERADE
fi

echo "Applying URLLC QoS rules..."
/bin/bash /scripts/apply-slice-qos.sh urllc ogstun

sleep 10
exec open5gs-upfd -c /opt/open5gs/etc/open5gs/upf-urllc.yaml

```

## scripts/controller/sla_dynamic_allocator.py

```python
#!/usr/bin/env python3
import argparse
import csv
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


URLLC_LATENCY_SLA_MS = 20.0
URLLC_LOSS_SLA_PERCENT = 0.1


def run(cmd, check=True):
    result = subprocess.run(cmd, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}\n{result.stderr.strip()}")
    return result.stdout


def docker_exec(container, command, check=True):
    return run(["docker", "exec", container, "sh", "-c", command], check=check)


def require_container(name):
    state = run(["docker", "inspect", "-f", "{{.State.Status}}", name], check=False).strip()
    if state != "running":
        raise RuntimeError(f"container {name} is not running")


def ogstun_tx_bytes(container):
    output = docker_exec(container, "awk '$1 ~ /ogstun:/ {print $10}' /proc/net/dev")
    return int(output.strip() or "0")


def measure_urlcc_ping(target, count):
    output = docker_exec(
        "ue-urllc",
        f"ping -I uesimtun0 {target} -c {count} -i 0.2",
        check=False,
    )
    times = [float(value) for value in re.findall(r"time=([0-9.]+)", output)]
    loss_match = re.search(r"([0-9.]+)% packet loss", output)
    loss = float(loss_match.group(1)) if loss_match else 100.0
    if not times:
        return 9999.0, loss
    times.sort()
    p95_index = min(len(times) - 1, int(round(0.95 * (len(times) - 1))))
    return times[p95_index], loss


def delete_qdisc(container):
    docker_exec(container, "tc qdisc del dev ogstun root 2>/dev/null || true", check=False)


def apply_limit(container, mbps, prio, target_ms):
    mbps = max(1, int(mbps))
    command = f"""
tc qdisc replace dev ogstun root handle 1: htb default 10 r2q 1000
tc class replace dev ogstun parent 1: classid 1:10 htb rate {mbps}mbit ceil {mbps}mbit burst 64k cburst 64k prio {prio}
tc qdisc replace dev ogstun parent 1:10 handle 10: fq_codel limit 256 target {target_ms}ms interval 100ms ecn
tc qdisc show dev ogstun >/dev/null
"""
    docker_exec(container, command)


def apply_mode(mode, embb_limit, urllc_limit):
    if mode == "no_slicing_baseline":
        delete_qdisc("upf-embb")
        delete_qdisc("upf-urllc")
        return 0, 0
    if mode in {"static_slicing", "dynamic_sla_slicing"}:
        apply_limit("upf-embb", embb_limit, prio=2, target_ms=5)
        apply_limit("upf-urllc", urllc_limit, prio=0, target_ms=1)
        return embb_limit, urllc_limit
    raise ValueError(mode)


def write_header(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "timestamp",
                "mode",
                "embb_mbps",
                "urllc_latency_ms",
                "urllc_loss_percent",
                "urllc_bw_limit",
                "embb_bw_limit",
            ]
        )


def append_row(path, row):
    with path.open("a", newline="") as handle:
        csv.writer(handle).writerow(row)


def main():
    parser = argparse.ArgumentParser(description="SLA-aware dynamic resource allocator for the 5G slicing lab")
    parser.add_argument(
        "--mode",
        choices=["no_slicing_baseline", "static_slicing", "dynamic_sla_slicing"],
        default="dynamic_sla_slicing",
    )
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--interval", type=int, default=3)
    parser.add_argument("--urllc-target", default="10.46.0.1")
    parser.add_argument("--ping-count", type=int, default=8)
    parser.add_argument("--total-mbps", type=int, default=100)
    parser.add_argument("--static-embb-mbps", type=int, default=70)
    parser.add_argument("--static-urllc-mbps", type=int, default=30)
    parser.add_argument("--min-urllc-mbps", type=int, default=10)
    parser.add_argument("--max-urllc-mbps", type=int, default=80)
    parser.add_argument("--step-mbps", type=int, default=10)
    parser.add_argument("--output", default="")
    args = parser.parse_args()

    for container in ["upf-embb", "upf-urllc", "ue-urllc"]:
        require_container(container)

    if args.output:
        csv_path = Path(args.output)
    else:
        run_id = datetime.now().strftime("%Y%m%d-%H%M%S")
        csv_path = Path("reports") / f"sla-dynamic-allocation-{args.mode}-{run_id}.csv"

    if args.mode == "no_slicing_baseline":
        embb_limit = 0
        urllc_limit = 0
    elif args.mode == "static_slicing":
        embb_limit = args.static_embb_mbps
        urllc_limit = args.static_urllc_mbps
    else:
        urllc_limit = max(args.min_urllc_mbps, min(args.max_urllc_mbps, args.static_urllc_mbps))
        embb_limit = max(1, args.total_mbps - urllc_limit)

    embb_limit, urllc_limit = apply_mode(args.mode, embb_limit, urllc_limit)
    write_header(csv_path)

    print(f"mode={args.mode} output={csv_path}")
    print("timestamp,mode,embb_mbps,urllc_latency_ms,urllc_loss_percent,urllc_bw_limit,embb_bw_limit")

    stable_cycles = 0
    previous_tx = ogstun_tx_bytes("upf-embb")
    end_time = time.time() + args.duration

    while time.time() < end_time:
        sample_start = time.time()
        time.sleep(args.interval)
        current_tx = ogstun_tx_bytes("upf-embb")
        elapsed = max(0.001, time.time() - sample_start)
        embb_mbps = max(0.0, (current_tx - previous_tx) * 8 / elapsed / 1_000_000)
        previous_tx = current_tx

        latency_ms, loss_percent = measure_urlcc_ping(args.urllc_target, args.ping_count)
        violation = latency_ms > URLLC_LATENCY_SLA_MS or loss_percent > URLLC_LOSS_SLA_PERCENT

        if args.mode == "dynamic_sla_slicing":
            if violation:
                stable_cycles = 0
                urllc_limit = min(args.max_urllc_mbps, urllc_limit + args.step_mbps)
                embb_limit = max(1, args.total_mbps - urllc_limit)
                apply_mode(args.mode, embb_limit, urllc_limit)
            else:
                stable_cycles += 1
                if stable_cycles >= 3 and urllc_limit > args.min_urllc_mbps:
                    urllc_limit = max(args.min_urllc_mbps, urllc_limit - args.step_mbps)
                    embb_limit = max(1, args.total_mbps - urllc_limit)
                    stable_cycles = 0
                    apply_mode(args.mode, embb_limit, urllc_limit)

        timestamp = datetime.now(timezone.utc).isoformat()
        row = [
            timestamp,
            args.mode,
            f"{embb_mbps:.3f}",
            f"{latency_ms:.3f}",
            f"{loss_percent:.3f}",
            urllc_limit,
            embb_limit,
        ]
        append_row(csv_path, row)
        print(",".join(map(str, row)), flush=True)

    print(f"CSV written: {csv_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)

```

