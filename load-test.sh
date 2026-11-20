#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
export PATH="$PWD/.kube/bin:$PATH"

exec python3 -u - "$@" <<'PY'
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

duration = sys.argv[1] if len(sys.argv) > 1 else "30s"
concurrency = sys.argv[2] if len(sys.argv) > 2 else "20"
assert len(sys.argv) <= 3 and re.fullmatch(r"[1-9][0-9]*s", duration)
assert concurrency.isdigit() and int(concurrency) > 0
context = "kind-kserve-lab2"
command = ["kubectl", f"--kubeconfig={os.environ['KUBECONFIG']}", f"--context={context}", "--cache-dir=.kube/cache"]
predictor = "sklearn-iris-predictor"
gateway = "kserve-ingress-gateway"
selector = f"gateway.envoyproxy.io/owning-gateway-name={gateway},gateway.envoyproxy.io/owning-gateway-namespace=kserve"
path = "/v1/models/sklearn-iris:predict"

def kubectl(*args):
    return subprocess.check_output([*command, *args], timeout=20, text=True)

def get(*args):
    return json.loads(kubectl("get", *args, "-o", "json"))

def service_hostname():
    isvc = get("-n", "lab2", "isvc", "sklearn-iris")
    assert isvc["status"]["deploymentMode"] == "Standard" and not isvc["spec"].get("canary")
    assert isvc["spec"]["predictor"]["model"]["storageUri"] == "gs://kfserving-examples/models/sklearn/1.0/model-2"
    assert any(c["type"] == "Ready" and c["status"] == "True" for c in isvc["status"]["conditions"])
    return urlsplit(isvc["status"]["url"]).hostname

def sample(stage):
    items = get("-n", "lab2", "hpa,deployment,pod")["items"]
    deployment, = [r for r in items if r["kind"] == "Deployment" and r["metadata"]["name"] == predictor]
    hpa, = [r for r in items if r["kind"] == "HorizontalPodAutoscaler" and r["metadata"]["name"] == predictor]
    hs, ds = hpa["status"], deployment["status"]
    cpu = next((m["resource"]["current"] for m in hs.get("currentMetrics", [])
                if m.get("resource", {}).get("name") == "cpu"), {})
    target, = hpa["spec"]["metrics"]
    assert hpa["spec"]["scaleTargetRef"]["name"] == predictor
    assert hpa["spec"]["minReplicas"] == 1 and hpa["spec"]["maxReplicas"] == 3
    assert target["resource"]["name"] == "cpu"
    goal = target["resource"]["target"]["averageUtilization"]
    active = any(c["type"] == "ScalingActive" and c["status"] == "True" for c in hs["conditions"])
    pods = []
    for pod in items:
        if pod["kind"] != "Pod" or pod["metadata"].get("labels", {}).get("app") != f"isvc.{predictor}":
            continue
        ready = any(c["type"] == "Ready" and c["status"] == "True" for c in pod["status"].get("conditions", []))
        name = pod["metadata"]["name"].removeprefix(predictor + "-")
        pods.append(f"{name}:{'Ready' if ready else pod['status']['phase']}")
    utilization = cpu.get("averageUtilization")
    cpu_text = f"{utilization}%/{goal}% ({cpu['averageValue']})" if utilization is not None else f"unknown/{goal}%"
    ready = ds.get("readyReplicas", 0)
    print(datetime.now(timezone.utc).isoformat(timespec="seconds"), stage, cpu_text,
          hs.get("currentReplicas", 0), hs.get("desiredReplicas", 0), ds.get("replicas", 0),
          ready, ",".join(sorted(pods)), sep="\t")
    return utilization, active, hs.get("desiredReplicas", 0), ready

def smoke(url, hostname):
    response = subprocess.check_output(
        ["curl", "--noproxy", "*", "-fsS", "--max-time", "15", "-H", f"Host: {hostname}",
         "-H", "Content-Type: application/json", "--data-binary", "@iris-input-v1.json", url], text=True)
    assert json.loads(response)["predictions"] == [1, 1], response
    return response.strip()

assert kubectl("config", "get-contexts", "-o", "name").strip() == context
assert kubectl("config", "current-context").strip() == context
hostname = service_hostname()
gateway_object = get("-n", "kserve", "gateway", gateway)
assert any(c["type"] == "Programmed" and c["status"] == "True" for c in gateway_object["status"]["conditions"])
listener, = [l for l in gateway_object["spec"]["listeners"] if l["protocol"] == "HTTP"]
route = get("-n", "lab2", "httproute", "sklearn-iris")
assert hostname in route["spec"]["hostnames"]
refs = route["spec"]["rules"][0]["backendRefs"]
assert [r["name"] for r in refs] == [predictor], refs
parent, = [p for p in route["status"]["parents"] if p["parentRef"]["name"] == gateway and p["parentRef"].get("namespace") == "kserve"]
assert {"Accepted", "ResolvedRefs"} <= {c["type"] for c in parent["conditions"] if c["status"] == "True"}
service, = get("svc", "-A", "-l", selector)["items"]
namespace, name = service["metadata"]["namespace"], service["metadata"]["name"]
port, = [p["port"] for p in service["spec"]["ports"] if p["port"] == listener["port"]]
load_path = f"{path}?lab_run={uuid.uuid4().hex}"

with tempfile.TemporaryDirectory(dir=".kube", prefix="phase5-load-") as temp:
    log = Path(temp) / "forward.log"
    output = Path(temp) / "hey.log"
    with log.open("w") as stream:
        forward = subprocess.Popen([*command, "-n", namespace, "port-forward", "--address", "127.0.0.1",
                                    f"svc/{name}", f":{port}"], stdout=stream, stderr=subprocess.STDOUT)
        try:
            for _ in range(20):
                local = re.search(r"^Forwarding from 127\.0\.0\.1:(\d+) -> ", log.read_text(), re.M)
                if local or forward.poll() is not None:
                    break
                time.sleep(0.5)
            assert local, log.read_text()
            url = f"http://127.0.0.1:{local[1]}{path}"
            args = ["hey", "-z", duration, "-c", concurrency, "-m", "POST", "-host", hostname,
                    "-T", "application/json", "-D", "iris-input-v1.json", f"http://127.0.0.1:{local[1]}{load_path}"]
            print(f"Gateway: {namespace}/{name}:{port} | HTTPRoute: lab2/sklearn-iris")
            print("Before inference HTTP 200:", smoke(url, hostname))
            print("Command:", shlex.join(args))
            print("UTC\tSTAGE\tCPU/TARGET (AVG)\tHPA_CURRENT\tHPA_DESIRED\tDEPLOY_CURRENT\tREADY\tPODS")
            cpu, active, desired, baseline = sample("BEFORE")
            assert cpu is not None and active and desired == baseline == 1, "Wait for 1 Ready replica and valid HPA CPU metrics."
            started = datetime.now(timezone.utc)
            peak_ready = during_ready = baseline
            envoy_sample = None
            with output.open("w") as stream:
                process = subprocess.Popen(args, stdout=stream, stderr=subprocess.STDOUT)
                try:
                    while process.poll() is None:
                        ready = sample("LOAD")[3]
                        if process.poll() is None:
                            during_ready = max(during_ready, ready)
                        peak_ready = max(peak_ready, ready)
                        # The active log can be empty after kubelet rotates it during a busy run.
                        if envoy_sample is None:
                            logs = kubectl("-n", namespace, "logs", "-l", selector, "-c", "envoy", "--tail=100")
                            for line in logs.splitlines():
                                if load_path in line:
                                    entry = json.loads(line)
                                    if (entry["response_code"] == 200 and entry["method"] == "POST"
                                            and entry["x-envoy-origin-path"] == load_path
                                            and entry[":authority"] == hostname
                                            and entry["response_code_details"] == "via_upstream"):
                                        envoy_sample = entry
                                        break
                        time.sleep(3)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
            hey_output = output.read_text()
            print("\nhey result\n" + hey_output, flush=True)
            if process.returncode != 0:
                raise SystemExit(f"hey exited with code {process.returncode}")
            status_counts = {int(code): int(total) for code, total in
                             re.findall(r"^\s*\[(\d{3})\]\s+(\d+)\s+responses", hey_output, re.M)}
            transport_errors = sum(map(int, re.findall(r"^\s*\[(\d+)\]", hey_output.partition("Error distribution:")[2], re.M)))
            end = time.monotonic()
            while True:
                cpu, active, desired, ready = sample("AFTER")
                peak_ready = max(peak_ready, ready)
                if peak_ready >= 2 and ready == desired == 1 and active and cpu is not None:
                    break
                if time.monotonic() - end >= (390 if peak_ready >= 2 else 85):
                    break
                time.sleep(5)
            if envoy_sample is not None:
                print("\nMatching Envoy upstream access log:", json.dumps(envoy_sample, separators=(",", ":")))
            assert service_hostname() == hostname
            print("After inference HTTP 200:", smoke(url, hostname))
        finally:
            if forward.poll() is None:
                forward.terminate()
                forward.wait(timeout=5)

events = get("-n", "lab2", "events",
             "--field-selector", f"involvedObject.kind=HorizontalPodAutoscaler,involvedObject.name={predictor}")["items"]
scaled_by_cpu = False
print("\nHPA events during or after load")
for event in sorted(events, key=lambda event: event.get("lastTimestamp") or event["metadata"]["creationTimestamp"]):
    stamp = event.get("lastTimestamp") or event["metadata"]["creationTimestamp"]
    if datetime.fromisoformat(stamp.replace("Z", "+00:00")) < started.replace(microsecond=0):
        continue
    print(stamp, event["reason"], event["message"])
    if event["reason"] == "SuccessfulRescale" and re.search(r"New size: [23].*cpu resource", event["message"]):
        scaled_by_cpu = True
print(f"\nHTTP 200 responses: {status_counts.get(200, 0)}")
print(f"Other HTTP responses: {sum(n for code, n in status_counts.items() if code != 200)}")
print(f"Transport errors: {transport_errors}")
print(f"Ready replicas (baseline / peak during hey / overall peak / final): {baseline} / {during_ready} / {peak_ready} / {ready}")
print(f"HPA CPU scale-up event: {scaled_by_cpu}")
assert status_counts.get(200, 0) > 0, "hey recorded no HTTP 200 responses"
assert envoy_sample is not None, "No matching Envoy upstream log was sampled during hey"
assert active and cpu is not None, "HPA final CPU metric unavailable"
assert scaled_by_cpu and peak_ready >= 2, "Batch did not prove CPU scale-up to 2 or more Ready replicas"
PY
