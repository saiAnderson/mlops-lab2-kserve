#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
lab=(kubectl --kubeconfig="$KUBECONFIG" --context=kind-kserve-lab2 --cache-dir="$PWD/.kube/cache")
test "$("${lab[@]}" config current-context)" = kind-kserve-lab2
# Standard Mode may report the Deployment generation in the InferenceService status.
ready=$("${lab[@]}" -n lab2 get isvc sklearn-iris -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
[[ "$ready" == True ]] || { printf 'Expected sklearn-iris Ready=True, got %s\n' "$ready" >&2; exit 1; }

url=$("${lab[@]}" -n lab2 get isvc sklearn-iris -o jsonpath='{.status.url}')
hostname=${url#http://}
gateway_port=$("${lab[@]}" -n kserve get gateway kserve-ingress-gateway -o jsonpath='{.spec.listeners[?(@.protocol=="HTTP")].port}')
route=$("${lab[@]}" -n lab2 get httproute -o json | python3 -c '
import json, sys
matches = [r for r in json.load(sys.stdin)["items"] if sys.argv[1] in r["spec"].get("hostnames", [])]
route, = matches
parent, = [p for p in route["status"]["parents"] if p["parentRef"]["name"] == "kserve-ingress-gateway" and p["parentRef"].get("namespace") == "kserve"]
conditions = {c["type"]: c["status"] for c in parent["conditions"]}
assert conditions["Accepted"] == conditions["ResolvedRefs"] == "True", conditions
print(route["metadata"]["name"])
' "$hostname")
gateway_selector=gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway,gateway.envoyproxy.io/owning-gateway-namespace=kserve
gateway=$("${lab[@]}" get svc -A -l "$gateway_selector" -o json | python3 -c '
import json, sys
service, = json.load(sys.stdin)["items"]
port, = [p["port"] for p in service["spec"]["ports"] if p["port"] == int(sys.argv[1])]
print(service["metadata"]["namespace"], service["metadata"]["name"], port)
' "$gateway_port")
read -r gateway_namespace gateway_service gateway_port <<< "$gateway"

output_dir=.kube/phase3/last-run
mkdir -p "$output_dir"
scratch=$(mktemp -d .kube/phase3/inference.XXXXXX)
"${lab[@]}" -n "$gateway_namespace" port-forward --address 127.0.0.1 "svc/$gateway_service" ":$gateway_port" > "$scratch/forward.log" 2>&1 &
forward_pid=$!
cleanup() {
  kill "$forward_pid" 2>/dev/null || true
  wait "$forward_pid" 2>/dev/null || true
  rm -r -- "$scratch"
}
trap cleanup EXIT

for attempt in {1..20}; do
  local_port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) -> .+$/\1/p' "$scratch/forward.log")
  [[ -n "$local_port" ]] && break
  kill -0 "$forward_pid" 2>/dev/null || break
  sleep 0.5
done
if [[ -z "$local_port" ]]; then
  cat "$scratch/forward.log" >&2
  exit 1
fi

request() {
  local protocol="$1" path="$2" output="$3" agent status access_log=""
  agent="mlops-lab2-$protocol-$(cat /proc/sys/kernel/random/uuid)"
  status=$(curl --noproxy '*' --silent --show-error --max-time 30 --request POST \
    --header "Host: $hostname" --header 'Content-Type: application/json' --user-agent "$agent" \
    --data-binary "@iris-input-$protocol.json" --dump-header "$scratch/$protocol.headers" \
    --output "$scratch/$protocol.json" --write-out '%{http_code}' "http://127.0.0.1:$local_port$path")
  if [[ "$status" != 200 ]]; then
    printf '%s HTTP %s\n' "$protocol" "$status" >&2
    cat "$scratch/$protocol.json" >&2
    exit 1
  fi
  # Envoy can buffer access logs before writing them to stdout.
  for attempt in {1..20}; do
    access_log=$("${lab[@]}" -n "$gateway_namespace" logs -l "$gateway_selector" -c envoy --tail=80 | grep -F -- "$agent" || true)
    [[ -n "$access_log" ]] && break
    sleep 1
  done
  if [[ -z "$access_log" ]]; then
    printf 'No matching Envoy access log for %s\n' "$agent" >&2
    cat "$scratch/$protocol.json" >&2
    exit 1
  fi
  printf '%s\n' "$access_log" | python3 -c '
import json, sys
entry = json.load(sys.stdin)
assert entry["method"] == "POST" and entry["response_code"] == 200, entry
assert entry["x-envoy-origin-path"] == sys.argv[1], entry
assert entry["route_name"].startswith(f"httproute/lab2/{sys.argv[2]}/"), entry
assert entry["response_code_details"] == "via_upstream" and entry["upstream_host"], entry
' "$path" "$route"
  {
    date --utc -Iseconds
    printf 'Gateway: %s/%s:%s -> HTTPRoute lab2/%s\n' "$gateway_namespace" "$gateway_service" "$gateway_port" "$route"
    printf 'POST http://127.0.0.1:%s%s\nHost: %s\nContent-Type: application/json\nUser-Agent: %s\n' "$local_port" "$path" "$hostname" "$agent"
    cat "iris-input-$protocol.json"
    printf '\nResponse (HTTP %s)\n' "$status"
    tr -d '\r' < "$scratch/$protocol.headers"
    cat "$scratch/$protocol.json"
    printf '\n\nEnvoy access log\n%s\n' "$access_log"
  } > "$scratch/$output"
}

request v1 /v1/models/sklearn-iris:predict 02-inference-v1.txt
request v2 /v2/models/sklearn-iris/infer 03-inference-v2.txt
python3 - "$scratch" <<'PY'
import json
import sys
from pathlib import Path

scratch = Path(sys.argv[1])
instances = json.loads(Path("iris-input-v1.json").read_text())["instances"]
tensor, = json.loads(Path("iris-input-v2.json").read_text())["inputs"]
assert tensor["datatype"] == "FP32" and tensor["shape"] == [len(instances), 4]
assert all(len(row) == 4 for row in instances)
assert tensor["data"] == [value for row in instances for value in row]

predictions = json.loads((scratch / "v1.json").read_text())["predictions"]
result = json.loads((scratch / "v2.json").read_text())
output, = result["outputs"]
assert result["model_name"] == "sklearn-iris"
assert len(predictions) == len(instances) and all(type(p) is int for p in predictions)
assert output["datatype"] == "INT32" and output["shape"] == [len(instances)], output
assert output["data"] == predictions and all(type(p) is int for p in output["data"])
print(f"PASS: V1 and V2 returned HTTP 200 and identical predictions {predictions}")
PY
cp -- "$scratch/02-inference-v1.txt" "$scratch/03-inference-v2.txt" "$output_dir/"
cat "$output_dir/02-inference-v1.txt" "$output_dir/03-inference-v2.txt"
