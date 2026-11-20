#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$BASH_SOURCE")/.."
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"

exec python3 -u - <<'PY'
import json
import os
import re
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

kube = ["kubectl", f"--kubeconfig={os.environ['KUBECONFIG']}", "--context=kind-kserve-lab2", "--cache-dir=.kube/cache"]
gateway = "kserve-ingress-gateway"
selector = f"gateway.envoyproxy.io/owning-gateway-name={gateway},gateway.envoyproxy.io/owning-gateway-namespace=kserve"
namespace = "lab2-bonus"
request = Path("bonus/chat-request.json")
chat_path = "/openai/v1/chat/completions"

def kubectl(*args):
    return subprocess.check_output([*kube, *args], text=True, timeout=20)

def get(*args):
    return json.loads(kubectl("get", *args, "-o", "json"))

def true_conditions(conditions):
    return {condition["type"] for condition in conditions if condition["status"] == "True"}

assert kubectl("config", "current-context").strip() == "kind-kserve-lab2"
isvc = get("-n", namespace, "isvc", "qwen")
assert isvc["status"]["deploymentMode"] == "Standard"
assert "Ready" in true_conditions(isvc["status"]["conditions"])
hostname = urlsplit(isvc["status"]["url"]).hostname
deployment = get("-n", namespace, "deployment", "qwen-predictor")
predictor, = [c for c in deployment["spec"]["template"]["spec"]["containers"] if c["name"] == "kserve-container"]
name, = [arg.split("=", 1)[1] for arg in predictor["args"] if arg.startswith("--model_name=")]
body = json.loads(request.read_text())
assert body["model"] == name, (body["model"], name)

gateway_object = get("-n", "kserve", "gateway", gateway)
assert "Programmed" in true_conditions(gateway_object["status"]["conditions"])
listener, = [listener for listener in gateway_object["spec"]["listeners"] if listener["name"] == "http"]
route = get("-n", namespace, "httproute", "qwen")
assert hostname in route["spec"]["hostnames"]
parent, = [p for p in route["status"]["parents"] if p["parentRef"]["name"] == gateway and p["parentRef"].get("namespace") == "kserve"]
assert {"Accepted", "ResolvedRefs"} <= true_conditions(parent["conditions"])
service, = get("svc", "-A", "-l", selector)["items"]
gateway_ns, gateway_service = service["metadata"]["namespace"], service["metadata"]["name"]
port, = [port["port"] for port in service["spec"]["ports"] if port["port"] == listener["port"]]

agent = "mlops-lab2-bonus-" + uuid.uuid4().hex
with tempfile.TemporaryDirectory(dir=".kube", prefix="bonus-chat-") as scratch:
    scratch = Path(scratch)
    forward_log = scratch / "forward.log"
    response_file = scratch / "response.json"
    with forward_log.open("w") as output:
        forward = subprocess.Popen([*kube, "-n", gateway_ns, "port-forward", "--address", "127.0.0.1",
                                    f"svc/{gateway_service}", f":{port}"], stdout=output, stderr=subprocess.STDOUT)
        try:
            local_port = None
            for _ in range(30):
                local_port = re.search(r"^Forwarding from 127\.0\.0\.1:(\d+) -> ", forward_log.read_text(), re.M)
                if local_port or forward.poll() is not None:
                    break
                time.sleep(0.4)
            assert local_port, forward_log.read_text()
            url = f"http://127.0.0.1:{local_port[1]}{chat_path}"
            print(f"InferenceService: {namespace}/qwen READY=True | Runtime model: {name}")
            print(f"Gateway: {gateway_ns}/{gateway_service}:{port} -> HTTPRoute {namespace}/qwen")
            print(f"POST {url}\nHost: {hostname}\nContent-Type: application/json\nUser-Agent: {agent}")
            print(f"\nRequest JSON\n{request.read_text().rstrip()}")
            status, duration = subprocess.check_output([
                "curl", "--noproxy", "*", "-sS", "--max-time", "75", "--request", "POST",
                "-H", f"Host: {hostname}", "-H", "Content-Type: application/json",
                "--user-agent", agent, "--data-binary", f"@{request}", "--output", str(response_file),
                "--write-out", "%{http_code} %{time_total}", url], text=True).split()
            response = response_file.read_text()
            print(f"\nResponse (HTTP {status}) | curl time_total: {duration}s\n{response}")
            assert status == "200", response
            reply = json.loads(response)
            assert "error" not in reply and reply["model"] == name
            message = reply["choices"][0]["message"]
            assert message["role"] == "assistant" and isinstance(message["content"], str) and message["content"].strip()
            for _ in range(20):
                logs = kubectl("-n", gateway_ns, "logs", "-l", selector, "-c", "envoy", "--tail=100")
                matches = [json.loads(line) for line in logs.splitlines() if agent in line]
                if matches:
                    break
                time.sleep(1)
            entry, = matches
            assert entry["method"] == "POST" and entry[":authority"] == hostname
            assert entry["x-envoy-origin-path"] == chat_path and entry["response_code"] == 200
            assert entry["response_code_details"] == "via_upstream" and entry["upstream_host"]
            assert entry["route_name"].startswith(f"httproute/{namespace}/qwen/")
            print("\nEnvoy upstream access log\n" + json.dumps(entry, separators=(",", ":")))
            print(f"\nGenerated text\n{message['content']}")
        finally:
            if forward.poll() is None:
                forward.terminate()
                forward.wait(timeout=5)
PY
