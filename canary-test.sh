#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"

exec python3 - "$@" <<'PY'
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

mode = sys.argv[1:]
if not 1 <= len(mode) <= 2 or mode[0] not in {"canary", "promoted"}:
    raise SystemExit("Usage: bash canary-test.sh {canary|promoted} [requests]")
canary = mode[0] == "canary"
count = int(mode[1]) if len(mode) == 2 else (20 if canary else 5)
if not 1 <= count <= 100:
    raise SystemExit("Request count must be between 1 and 100.")

context = "kind-kserve-lab2"
command = ["kubectl", f"--kubeconfig={os.environ['KUBECONFIG']}", f"--context={context}", "--cache-dir=.kube/cache"]
model_root = "gs://kfserving-examples/models/sklearn/1.0"
stable = "sklearn-iris-predictor"
candidate = "sklearn-iris-model-2-predictor"
services = {stable: "model", candidate: "model-2"} if canary else {stable: "model-2"}
gateway = "kserve-ingress-gateway"
gateway_selector = f"gateway.envoyproxy.io/owning-gateway-name={gateway},gateway.envoyproxy.io/owning-gateway-namespace=kserve"
path = "/v1/models/sklearn-iris:predict"

def kubectl(*args):
    return subprocess.check_output([*command, *args], text=True, timeout=20)

def lab_get(*args):
    return json.loads(kubectl("-n", "lab2", "get", *args, "-o", "json"))

def snapshot():
    isvc = lab_get("isvc", "sklearn-iris")
    spec, status = isvc["spec"], isvc["status"]
    conditions = {c["type"]: c["status"] for c in status["conditions"]}
    assert status["deploymentMode"] == "Standard" and conditions["Ready"] == "True", conditions
    assert spec["predictor"]["model"]["storageUri"] == f"{model_root}/{'model' if canary else 'model-2'}"
    if canary:
        configured, = spec["canary"]
        observed, = status["canaryStatuses"]
        assert configured["trafficPercent"] == observed["trafficPercent"] == 20
        assert configured["predictor"]["name"] == observed["name"] == "model-2"
        assert configured["predictor"]["model"]["storageUri"] == f"{model_root}/model-2"
        assert conditions["CanaryPredictorReady"] == "True" and observed["ready"]
    else:
        assert not spec.get("canary") and not spec["predictor"].get("name")

    hostname = urlsplit(status["url"]).hostname
    weights = {}
    for route in lab_get("httproute", "sklearn-iris", "sklearn-iris-predictor")["items"]:
        name = route["metadata"]["name"]
        if name == "sklearn-iris":
            assert hostname in route["spec"]["hostnames"], route["spec"]
        parent, = [p for p in route["status"]["parents"]
                   if p["parentRef"]["name"] == gateway and p["parentRef"].get("namespace") == "kserve"]
        generation = route["metadata"]["generation"]
        ready = {c["type"] for c in parent["conditions"]
                 if c["status"] == "True" and c["observedGeneration"] == generation}
        assert {"Accepted", "ResolvedRefs"} <= ready, parent
        for rule in route["spec"]["rules"]:
            refs = rule["backendRefs"]
            assert all(r.get("namespace", "lab2") == "lab2" and r["port"] == 80 for r in refs)
            refs_by_name = {ref["name"]: ref.get("weight", 1) for ref in refs}
            assert len(refs_by_name) == len(refs)
            if canary:
                assert refs_by_name == {stable: 80, candidate: 20}, refs_by_name
            else:
                assert list(refs_by_name) == [stable] and refs_by_name[stable] > 0, refs_by_name
            weights[name] = refs_by_name

    pods = {p["metadata"]["name"]: p for p in lab_get("pods")["items"]}
    endpoints = {}
    for name, model in services.items():
        address_count = 0
        for item in lab_get("endpointslice", "-l", f"kubernetes.io/service-name={name}")["items"]:
            for endpoint in item["endpoints"]:
                if not endpoint["conditions"].get("ready") or endpoint["conditions"].get("terminating"):
                    continue
                pod_ref = endpoint["targetRef"]
                pod = pods[pod_ref["name"]]
                assert pod["metadata"]["uid"] == pod_ref["uid"]
                assert any(c["type"] == "Ready" and c["status"] == "True" for c in pod["status"]["conditions"])
                initializer, = [c for c in pod["spec"]["initContainers"] if c["name"] == "storage-initializer"]
                uri = f"{model_root}/{model}"
                assert uri in initializer["args"], initializer["args"]
                assert pod["status"]["podIP"] in endpoint["addresses"], endpoint
                for port in item["ports"]:
                    address = f"{pod['status']['podIP']}:{port['port']}"
                    assert address not in endpoints, address
                    endpoints[address] = {"service": name, "model": model, "uri": uri,
                                          "pod": pod_ref["name"], "podUID": pod_ref["uid"]}
                    address_count += 1
        assert address_count, f"No ready EndpointSlice address for {name}"
    return hostname, weights, endpoints

assert kubectl("config", "get-contexts", "-o", "name").strip() == context
assert kubectl("config", "current-context").strip() == context
hostname, weights, endpoints = before = snapshot()
listener, = [l for l in json.loads(kubectl("-n", "kserve", "get", "gateway", gateway, "-o", "json"))["spec"]["listeners"]
             if l["protocol"] == "HTTP"]
service, = json.loads(kubectl("get", "svc", "-A", "-l", gateway_selector, "-o", "json"))["items"]
namespace, gateway_service = service["metadata"]["namespace"], service["metadata"]["name"]
gateway_port, = [p["port"] for p in service["spec"]["ports"] if p["port"] == listener["port"]]

run_id = f"mlops-lab2-phase4-{uuid.uuid4().hex}"
attempts = {}
with tempfile.TemporaryDirectory(dir=".kube", prefix="phase4-forward-") as temp:
    logfile = Path(temp) / "port-forward.log"
    with logfile.open("w") as stream:
        forward = subprocess.Popen(
            [*command, "-n", namespace, "port-forward", "--address", "127.0.0.1",
             f"svc/{gateway_service}", f":{gateway_port}"], stdout=stream, stderr=subprocess.STDOUT)
        try:
            for _ in range(20):
                match = re.search(r"^Forwarding from 127\.0\.0\.1:(\d+) -> ", logfile.read_text(), re.M)
                if match or forward.poll() is not None:
                    break
                time.sleep(0.5)
            if not match:
                raise SystemExit(logfile.read_text())
            url = f"http://127.0.0.1:{match[1]}{path}"

            for index in range(1, count + 1):
                agent = f"{run_id}-{index:03}"
                response = subprocess.run(
                    ["curl", "--noproxy", "*", "-sS", "--max-time", "15", "-X", "POST",
                     "-A", agent, "-H", f"Host: {hostname}", "-H", "Content-Type: application/json",
                     "--data-binary", "@iris-input-v1.json", "--write-out", "\n%{http_code}", url],
                    capture_output=True, text=True)
                body, _, status = response.stdout.rpartition("\n")
                attempts[agent] = (status if response.returncode == 0 else "000", body, response.stderr.strip())
        finally:
            if forward.poll() is None:
                forward.terminate()
                forward.wait(timeout=5)

# Envoy access logs may arrive after curl has finished. Keep one exact agent per attempt.
for _ in range(35):
    entries = {agent: [] for agent in attempts}
    for line in kubectl("-n", namespace, "logs", "-l", gateway_selector, "-c", "envoy", "--tail=500").splitlines():
        if run_id in line:
            record = json.loads(line)
            entries[record["user-agent"]].append(record)
    if all(entries.values()):
        break
    time.sleep(1)

try:
    unchanged = snapshot() == before
except (AssertionError, KeyError, ValueError, subprocess.SubprocessError) as error:
    print(f"Post-test route or endpoint check failed: {error}", file=sys.stderr)
    unchanged = False

counts = Counter()
rows = []
failed = invalid = 0
for agent, (status, body, error) in attempts.items():
    records = entries[agent]
    record = records[0] if len(records) == 1 else {}
    upstream = record.get("upstream_host")
    verified = (
        unchanged and record.get("method") == "POST" and record.get("x-envoy-origin-path") == path
        and record.get(":authority") == hostname and str(record.get("response_code")) == status
        and record.get("response_code_details") == "via_upstream"
        and record.get("route_name", "").startswith("httproute/lab2/sklearn-iris/")
        and upstream in endpoints
    )
    version = endpoints[upstream]["model"] if verified else "unattributed"
    counts[version] += 1
    failed += status != "200"
    if status == "200":
        try:
            predictions = json.loads(body)["predictions"]
            assert isinstance(predictions, list) and len(predictions) == 2 and all(type(v) is int for v in predictions)
        except (AssertionError, KeyError, TypeError, ValueError):
            invalid += 1
    rows.append((agent, status, version, upstream, record.get("x-request-id"), body, error))

assert sum(counts.values()) == count
print(f"Phase 4 {'Canary 80/20' if canary else 'Promotion'} | {datetime.now(timezone.utc).isoformat(timespec='seconds')}")
print(f"InferenceService: lab2/sklearn-iris Ready=True{' CanaryPredictorReady=True' if canary else ''}")
print(f"Gateway: {namespace}/{gateway_service}:{gateway_port} | Host: {hostname}")
print(f"HTTPRoute lab2/sklearn-iris weights: {json.dumps(weights['sklearn-iris'])}")
print(f"Total Requests: {count}")
for label, version in (("Stable" if canary else "Old Stable", "model"), ("Canary" if canary else "Promoted", "model-2")):
    print(f"{label} Requests ({version}): {counts[version]} ({100 * counts[version] / count:.2f}%)")
print(f"Failed Requests (non-200 or transport): {failed}")
print(f"Unattributed Requests: {counts['unattributed']}")
print(f"Invalid HTTP 200 Predictions: {invalid}")
print(f"Route and ready endpoints unchanged across batch: {unchanged}")

print(f"\nGateway request URL: {url}")
print(f"Request body: {Path('iris-input-v1.json').read_text().strip()}")
print(f"All HTTPRoute weights: {json.dumps(weights)}")
print(f"Ready EndpointSlice to Pod mapping: {json.dumps(endpoints, indent=2)}")
print("\nUser-Agent\tHTTP\tModel\tUpstream\tEnvoy request ID\tResponse\tCurl error")
for row in rows:
    print(*row, sep="\t")
print("\nMatched Envoy access logs (JSON Lines)")
for records in entries.values():
    for record in records:
        print(json.dumps(record, separators=(",", ":")))
sys.exit(bool(failed or invalid or counts["unattributed"]))
PY
