"""Render the v0.21.0 Quickstart's KServe core and scikit-learn runtime."""

import hashlib
import json
import sys
from pathlib import Path

import yaml


directory = Path(sys.argv[1])
quickstart = (directory / "official-quickstart.sh").read_bytes()
runtimes = (directory / "kserve-cluster-resources.yaml").read_bytes()
if hashlib.sha256(quickstart).hexdigest() != "22f15db71f918553150c347e7c03de504ee24bd177d14960fe38301bce87f93e":
    raise SystemExit("Unexpected KServe Quickstart digest")
if hashlib.sha256(runtimes).hexdigest() != "677b0c9d6e418048f56bbec34e986df52fa258fe96762985f72a6472c8efaffd":
    raise SystemExit("Unexpected KServe runtime bundle digest")

manifest = quickstart.decode().split("cat <<'KSERVE_CORE_MANIFEST_EOF'\n", 1)[1]
core = [item for item in yaml.safe_load_all(manifest.split("\nKSERVE_CORE_MANIFEST_EOF", 1)[0]) if item]
config = next(item for item in core if item['kind'] == 'ConfigMap' and item['metadata']['name'] == 'inferenceservice-config')
overrides = {
    "deploy": {"defaultDeploymentMode": "Standard"},
    "ingress": {"enableGatewayApi": True, "kserveIngressGateway": "kserve/kserve-ingress-gateway"},
}
for key, values in overrides.items():
    config["data"][key] = json.dumps(json.loads(config["data"][key]) | values)

runtime = next(
    item for item in yaml.safe_load_all(runtimes)
    if item and item['kind'] == 'ClusterServingRuntime' and item['metadata']['name'] == 'kserve-sklearnserver'
)
(directory / "kserve-standard-core.yaml").write_text(yaml.safe_dump_all(core, sort_keys=False))
(directory / "kserve-sklearnserver.yaml").write_text(yaml.safe_dump(runtime, sort_keys=False))
