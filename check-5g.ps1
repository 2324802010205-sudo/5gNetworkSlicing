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
    if ($LASTEXITCODE -eq 0 -and ($qdisc -match "htb|tbf|netem")) {
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
    "gnb", "ue-embb", "ue-urllc", "pushgateway", "node-exporter", "cadvisor"
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
