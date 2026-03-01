# 5G Network Slicing Lab
## Open5GS + UERANSIM + Docker

## Yêu cầu
- Ubuntu 22.04 LTS
- Docker + Docker Compose
- RAM tối thiểu 8GB
- CPU 4 cores

## Cách chạy

### 1. Clone repo
git clone <repo-url>
cd 5g-lab

### 2. Khởi động 5G Core
docker compose up -d

### 3. Khởi động RAN (gNB + UE)
docker compose -f docker-compose-ueransim.yaml up -d

### 4. Fix ogstun IP (QUAN TRỌNG - chạy mỗi lần restart)
docker exec -u root upf-embb ip addr del 10.45.0.1/16 dev ogstun
docker exec -u root upf-embb ip addr add 10.45.0.254/16 dev ogstun
docker exec -u root upf-urllc ip addr del 10.45.0.1/16 dev ogstun
docker exec -u root upf-urllc ip addr add 10.45.0.254/16 dev ogstun

### 5. Fix NAT + Routing trên HOST
sudo sysctl -w net.ipv4.ip_forward=1
sudo iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o ens33 -j MASQUERADE
sudo iptables -P FORWARD ACCEPT

### 6. Fix FORWARD trong UPF
docker exec -u root upf-embb iptables -t nat -A POSTROUTING -s 10.45.0.0/16 -o eth0 -j MASQUERADE
docker exec -u root upf-embb iptables -I FORWARD -i ogstun -o eth0 -j ACCEPT
docker exec -u root upf-embb iptables -I FORWARD -i eth0 -o ogstun -j ACCEPT

### 7. Test kết nối
docker exec -it ue ping -I uesimtun0 1.1.1.1 -c 4

## Kiến trúc
UE (10.45.0.1) → uesimtun0 → gNB → AMF → UPF-eMBB (SST=1) → Internet
UE (10.45.0.2) → uesimtun0 → gNB → AMF → UPF-uRLLC (SST=2) → Internet

## WebUI quản lý thuê bao
http://localhost:9999
User: admin / Password: 1423

## Giai đoạn 4 - TODO (thành viên C)
- [ ] Cấu hình QoS TBF/HTB cho UPF-eMBB (100Mbps)
- [ ] Cấu hình QoS HTB prio cho UPF-uRLLC (20Mbps, latency <10ms)
- [ ] Cấu hình Linux Cgroups cô lập tài nguyên
- [ ] Thêm Grafana + Prometheus monitoring
- [ ] Đo lường và so sánh kết quả 2 slice
