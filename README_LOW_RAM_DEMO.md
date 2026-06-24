# Low-RAM 5G Network Slicing Demo

## Recommended VMware settings for this project

Option A stable:

- Memory: 5120 MB
- Processors: 1
- Cores per processor: 4

Option B higher CPU:

- Memory: 5120 MB
- Processors: 1
- Cores per processor: 6

Do not increase RAM to 8GB if the Windows host becomes laggy.

The monitoring stack is optional and should only run during a demo. Keep
`cadvisor`, `node-exporter`, and `webui` stopped in the 5GB VM.

## Recommended workflow

```bash
cd ~/5g-lab
bash scripts/check-vm-resources.sh
bash scripts/low-ram-mode.sh --stop-monitoring
bash scripts/recalibrate-after-upgrade.sh
docker compose --profile monitoring up -d prometheus pushgateway grafana
bash scripts/demo-sla-violation.sh
```

Re-run calibration after changing VM vCPU or RAM. The generated
`reports/capacity.env` contains testbed-specific safe allocations; it is not a
claim about standard 5G QoS capacity.

`tc/htb/netem/fq_codel` is only a testbed proxy for resource pressure and
policy enforcement, not standard 5G QoS.
