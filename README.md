# MLOps Lab 2 · Serving Models with KServe

## Project Overview

本專案依課程講義第 49–50 頁及 TA 正式公告，交付 sklearn-iris 部署、V1／V2 推論、Canary／Promotion 與 CPU Autoscaling 的可重現設定及真實執行紀錄。依下列階段順序可在獨立的 `kserve-lab2` 重現。已完成的實測與截圖狀態見本頁末尾的交付清單。

## Architecture

WSL 的 `curl` 或 `hey` 經本機 port-forward 連到 **Envoy Gateway Service**。Gateway API 的 `HTTPRoute` 把請求送到 `lab2` 中由 KServe Standard 管理的 sklearn predictor Service 和 Pod。Canary 階段使用兩個加權後端，Promotion 後只剩 `model-2` 的正式後端。Metrics Server 從 kubelet 擷取 CPU 資料，KServe 管理的 HPA 用這些資料調整 predictor Deployment 副本數。

## Phase 2A：建立獨立的 kind 叢集

在 WSL2 Ubuntu 的 Bash 中執行。kind v0.33.0 使用固定的 Kubernetes v1.36.4 節點映像，符合 KServe v0.21.0 Standard 模式的 Kubernetes v1.32+ 需求，也與現有 `kubectl v1.37.1` 相差一個次版本。這階段只建立 Kubernetes 環境。[kind v0.33.0 映像清單](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0) · [KServe Standard 版本需求](https://kserve.github.io/website/docs/admin-guide/kubernetes-deployment) · [kubectl 版本相容規則](https://kubernetes.io/releases/version-skew-policy/#kubectl)

### 盤點及建立

先檢查現有叢集、預設 context 及預設 kubeconfig 雜湊。若 `kind get clusters` 已列出 `kserve-lab2`，直接使用下方驗證步驟。

```bash
cd ~/projects/mlops-lab2
kind version
kind get clusters
kubectl config current-context
sha256sum "$HOME/.kube/config"
kubectl version --client
```

```bash
LAB_KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
mkdir -p -m 700 .kube
(
  umask 077
  KUBECONFIG="$LAB_KUBECONFIG" KIND_EXPERIMENTAL_PROVIDER=docker kind create cluster \
    --name kserve-lab2 \
    --image 'kindest/node:v1.36.4@sha256:099e049362a1526b2db71494e1947aae99bd16290d7c895f2b7ea312e3cbfaed' \
    --kubeconfig="$LAB_KUBECONFIG" --wait 5m
)
```

### 驗證

```bash
LAB_KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
lab=(kubectl --kubeconfig "$LAB_KUBECONFIG" --context kind-kserve-lab2 --cache-dir "$PWD/.kube/cache")

kubectl --kubeconfig "$LAB_KUBECONFIG" config get-contexts -o name
kubectl --kubeconfig "$LAB_KUBECONFIG" config current-context
"${lab[@]}" version
"${lab[@]}" get --raw='/readyz?verbose'
"${lab[@]}" wait --for=condition=Ready nodes --all --timeout=120s
"${lab[@]}" wait --for=condition=Ready pods --all --all-namespaces --timeout=180s
"${lab[@]}" get nodes -o wide
"${lab[@]}" get pods --all-namespaces

kind get clusters
kubectl config current-context
sha256sum "$HOME/.kube/config"
```

本次 Lab context 為 `kind-kserve-lab2`、Server 為 `v1.36.4`，`/readyz` 回報 `readyz check passed`。控制平面 Ready，9 個內建 Pods 全數 `1/1 Running`。建置前後比對 `test-cluster` 的節點、系統 Pod 與 Docker 容器識別資料均一致。

初次跨 Windows 殼層下指令時，kind 將新 context 寫入了預設 kubeconfig。已使用 `kind export kubeconfig --name=kserve-lab2 --kubeconfig="$LAB_KUBECONFIG"` 匯出獨立檔案，並按建置前的 SHA-256 核對及還原預設 kubeconfig。預設 context 已復原至 `kind-test-cluster`。重現建置時請在 WSL Bash 內執行上述指令。

### Phase 2B 的 kubeconfig

`.kube/kserve-lab2.yaml` 含叢集存取憑證，整個 `.kube/` 已由 Git 忽略。後續安裝前先確認這份檔案只有 `kind-kserve-lab2` context。明確傳入 `--kubeconfig "$LAB_KUBECONFIG"`，或只對已審閱的安裝程序設定 `KUBECONFIG="$LAB_KUBECONFIG"`，讓子程序也使用同一份檔案。

## Phase 2B：KServe v0.21.0 Standard

在既有 `kserve-lab2` 上以原生 WSL Ubuntu Bash 安裝。盤點時 Docker 為 29.9.1，Kubernetes 為 v1.36.4，API `/readyz` 為 `ok`，WSL 有 13 GiB 可用 RAM。Helm 未安裝。已下載官方 v0.21.0 Quickstart 腳本、核對 GitHub Release SHA-256 並執行 `bash -n`。該腳本會安裝 Helm、Kustomize 和 yq，因此本次直接套用官方 manifests 與腳本內嵌的 KServe core YAML。所有叢集指令使用專用 kubeconfig 與指定 context。[KServe Quickstart](https://kserve.github.io/website/docs/getting-started/quickstart-guide) · [KServe Standard 安裝指南](https://kserve.github.io/website/docs/admin-guide/kubernetes-deployment)

### Environment & Versions

| 元件 | 實測版本與設定 |
|---|---|
| 主機工具 | WSL2 Ubuntu 24.04、Docker 29.9.1、kind v0.33.0、kubectl v1.37.1 |
| Kubernetes | v1.36.4，獨立 context `kind-kserve-lab2` |
| cert-manager | v1.21.3，提供 KServe admission webhook 憑證 |
| Envoy Gateway | v1.9.1，data plane 為 Envoy Proxy `distroless-v1.39.1` |
| Gateway API | v1.6.1，由 Envoy Gateway v1.9.1 發行檔提供 |
| KServe Controller 和 scikit-learn Runtime | v0.21.0，`defaultDeploymentMode=Standard`，`enableGatewayApi=true` |
| HTTP Gateway | `kserve/kserve-ingress-gateway`，內部 ClusterIP 80/TCP，允許 `lab2` 命名空間掛載路由。設定見 [infra/gateway.yaml](infra/gateway.yaml)。 |
| Metrics Server | v0.9.0 |
| hey | Ubuntu 套件 `0.1.4-2ubuntu0.24.04.3` |

曾先套用 Quickstart 對應的 Envoy Gateway v1.8.1。確認該系列相容矩陣未涵蓋 Kubernetes v1.36 後，已就地更新至 v1.9.1 並驗證 rollout。重現時直接使用 v1.9.1。[Envoy Gateway 相容矩陣](https://gateway.envoyproxy.io/news/releases/matrix/) · [cert-manager 支援版本](https://cert-manager.io/docs/releases/)

### Installation & Reproduction

以下使用 WSL Ubuntu 上既有的 `python3` 與 PyYAML 6.0.1。兩個 context 檢查及 API readiness 都通過後再繼續。下載與產生的 manifests 保存在 Git 忽略的 `.kube/phase2b/`。[KServe v0.21.0 Release](https://github.com/kserve/kserve/releases/tag/v0.21.0) · [Envoy Gateway v1.9.1 Release](https://github.com/envoyproxy/gateway/releases/tag/v1.9.1) · [cert-manager v1.21.3 Release](https://github.com/cert-manager/cert-manager/releases/tag/v1.21.3)

```bash
cd ~/projects/mlops-lab2
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
k=(kubectl --kubeconfig="$KUBECONFIG" --context=kind-kserve-lab2 --cache-dir="$PWD/.kube/cache")
test "$(kubectl config get-contexts -o name)" = kind-kserve-lab2
test "$(kubectl config current-context)" = kind-kserve-lab2
"${k[@]}" get --raw=/readyz

d=.kube/phase2b
mkdir -p -m 700 "$d"
ks=https://github.com/kserve/kserve/releases/download/v0.21.0
curl -fsSL "$ks/kserve-standard-mode-full-install-with-manifests.sh" -o "$d/official-quickstart.sh"
curl -fsSL "$ks/kserve-crds.yaml" -o "$d/kserve-crds.yaml"
curl -fsSL "$ks/kserve-cluster-resources.yaml" -o "$d/kserve-cluster-resources.yaml"
curl -fsSL https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml -o "$d/cert-manager.yaml"
curl -fsSL https://github.com/envoyproxy/gateway/releases/download/v1.9.1/install.yaml -o "$d/envoy-gateway-v1.9.1.yaml"
sha256sum --check <<EOF
a89e68c158fa56fed94c6fbfd1b83e16c44c027e7dc24b5fb01a988570ded013  $d/kserve-crds.yaml
c04a51295adda2b1a775146751f973e787190778c7f35180861d9678876e5c74  $d/cert-manager.yaml
72b3971364f172eb0b9636c7142cc84ff695467bc065897958bde85a3c06cfd5  $d/envoy-gateway-v1.9.1.yaml
EOF
python3 infra/render-kserve-standard.py "$d"

"${k[@]}" apply --server-side -f "$d/cert-manager.yaml"
"${k[@]}" apply --server-side -f "$d/envoy-gateway-v1.9.1.yaml"
"${k[@]}" -n cert-manager wait --for=condition=Available deployment --all --timeout=240s
"${k[@]}" -n envoy-gateway-system rollout status deployment/envoy-gateway --timeout=240s
"${k[@]}" create namespace kserve --dry-run=client -o yaml | "${k[@]}" apply --server-side -f -
"${k[@]}" apply --server-side -f "$d/kserve-crds.yaml"
"${k[@]}" wait --for=condition=Established crd/inferenceservices.serving.kserve.io crd/clusterservingruntimes.serving.kserve.io --timeout=90s
"${k[@]}" apply --server-side -f "$d/kserve-standard-core.yaml"
"${k[@]}" apply --server-side -f infra/gateway.yaml
"${k[@]}" -n kserve wait --for=condition=Ready certificate/serving-cert --timeout=150s
"${k[@]}" -n kserve rollout status deployment/kserve-controller-manager --timeout=300s
"${k[@]}" apply --server-side -f "$d/kserve-sklearnserver.yaml"
"${k[@]}" -n kserve wait --for=condition=Programmed gateway/kserve-ingress-gateway --timeout=180s
```

### 驗證紀錄

```bash
"${k[@]}" -n kserve get deployment kserve-controller-manager
"${k[@]}" get crd inferenceservices.serving.kserve.io
"${k[@]}" get clusterservingruntime kserve-sklearnserver
"${k[@]}" -n kserve get configmap inferenceservice-config -o jsonpath='{.data.deploy}{"\n"}{.data.ingress}{"\n"}'
"${k[@]}" -n envoy-gateway-system get deployment
"${k[@]}" -n kserve get gateway kserve-ingress-gateway
"${k[@]}" get pods -A
"${k[@]}" get events -A --field-selector type=Warning --sort-by=.lastTimestamp
"${k[@]}" get inferenceservices -A
```

- `kserve-controller-manager` Deployment `1/1 Available`，Pod `2/2 Running`。InferenceService CRD 已建立，`kserve-sklearnserver` 支援 V1 和 V2。
- GatewayClass `Accepted=True`，Gateway 與 HTTP listener `Programmed=True`。Envoy controller 與資料面 Deployment 各為 `1/1 Available`。目前共有 15 個 Running／Ready Pods，均無重啟。
- 歷史 Warning 包括叢集啟動時短暫的排程與 readiness 訊息，以及 Envoy 與 KServe 在憑證 Secret 產生前的 `FailedMount`。最終憑證 Ready，兩個 Deployment 均 Available，沒有未解決的 Warning。`InferenceService` 清單為空。
- `test-cluster` 的容器 ID、啟動時間、重啟次數和 IP 與安裝前一致。預設和專用 kubeconfig 的 SHA-256 均未改變，預設 context 為 `kind-test-cluster`。

## Phase 3｜InferenceService Deployment

PPT 第 49–50 頁指定部署 `sklearn-iris` 並測試兩種協定，Cheat Sheet 將完整 YAML 和範例輸入指向另一張投影片。因此本次採用 KServe v0.21 官方範例的公開模型目錄 `gs://kfserving-examples/models/sklearn/1.0/model` 與兩筆 Iris 特徵。WSL 對 `model.joblib` 的 HTTPS 檔案檢查回傳 `200`，Lab 內的 `storage-initializer` 也記錄下載成功，InferenceService 顯示 `ActiveModelState=Loaded`。同一份 InferenceService 使用 Standard、`kserve-sklearnserver` 與 `protocolVersion: v2`，實測同時支援 V1 和 V2 HTTP。 [sklearn-iris.yaml](sklearn-iris.yaml) · [官方 V1 範例](https://kserve.github.io/website/docs/getting-started/predictive-first-isvc#5-perform-inference) · [官方 scikit-learn V2 範例](https://kserve.github.io/website/docs/model-serving/predictive-inference/frameworks/sklearn) · [v0.21.0 Runtime](https://raw.githubusercontent.com/kserve/kserve/v0.21.0/config/runtimes/kserve-sklearnserver.yaml)

### 部署與驗證

```bash
cd ~/projects/mlops-lab2
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
lab=(kubectl --kubeconfig="$KUBECONFIG" --context=kind-kserve-lab2 --cache-dir="$PWD/.kube/cache")
"${lab[@]}" config current-context
"${lab[@]}" create namespace lab2 --dry-run=client -o yaml | "${lab[@]}" apply --server-side -f -
"${lab[@]}" apply --server-side --dry-run=server -f sklearn-iris.yaml
"${lab[@]}" apply --server-side -f sklearn-iris.yaml
"${lab[@]}" -n lab2 rollout status deployment/sklearn-iris-predictor --timeout=240s
test "$("${lab[@]}" -n lab2 get isvc sklearn-iris -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True
"${lab[@]}" -n lab2 get isvc
"${lab[@]}" -n lab2 describe isvc sklearn-iris
"${lab[@]}" -n lab2 get pods
"${lab[@]}" -n lab2 get httproute sklearn-iris -o wide
```

### 從 WSL 經 Envoy Gateway 呼叫

`status.url` 給出 `sklearn-iris-lab2.example.com`。`lab2/sklearn-iris` HTTPRoute 的 `Accepted`、`ResolvedRefs` 均為 `True`，指向 `lab2/sklearn-iris-predictor:80`。從 WSL 轉發的是 `envoy-gateway-system/envoy-kserve-kserve-ingress-gateway-deaaa49b` 的 HTTP 80。測試腳本從叢集查詢 Service、路由和 Host，自動選用本機連接埠。每筆證據都保留相符的 Envoy 存取日誌，包含 `response_code_details=via_upstream`、路由名稱及上游端點。 [test-inference.sh](test-inference.sh) · [Envoy 存取日誌欄位](https://gateway.envoyproxy.io/v1.9/tasks/observability/proxy-accesslog/#default-access-log)

```bash
bash test-inference.sh
```

重跑輸出寫入 `.kube/phase3/last-run/`，本次繳交的原始 evidence 保持原樣。

若要逐筆重現，可用上方已設定 `lab` 的 WSL Bash 開啟 Gateway port-forward。

```bash
"${lab[@]}" -n envoy-gateway-system port-forward --address 127.0.0.1 \
  svc/envoy-kserve-kserve-ingress-gateway-deaaa49b 18080:80
```

在另一個 WSL 終端機從專案目錄送出請求。兩份輸入包含相同的兩筆、每筆四欄特徵。

```bash
curl --noproxy '*' -sS -i -X POST -H 'Host: sklearn-iris-lab2.example.com' \
  -H 'Content-Type: application/json' --data-binary @iris-input-v1.json \
  http://127.0.0.1:18080/v1/models/sklearn-iris:predict

curl --noproxy '*' -sS -i -X POST -H 'Host: sklearn-iris-lab2.example.com' \
  -H 'Content-Type: application/json' --data-binary @iris-input-v2.json \
  http://127.0.0.1:18080/v2/models/sklearn-iris/infer
```

### V1/V2 Prediction Results

| 驗收項目 | 實際結果 | 原始輸出 |
|---|---|---|
| 部署 | `READY=True`、`DeploymentMode=Standard`，predictor `1/1 Running` | [01-isvc-ready.txt](evidence/01-isvc-ready.txt) |
| V1 | HTTP 200，`predictions=[1,1]` | [02-inference-v1.txt](evidence/02-inference-v1.txt) |
| V2 | HTTP 200，`outputs[0].data=[1,1]`，shape `[2]`，datatype `INT32`。輸入為 shape `[2,4]` 的 `FP32` | [03-inference-v2.txt](evidence/03-inference-v2.txt) |

`test-cluster` 容器 ID、啟動時間、重啟次數和 IP 均與部署前相同，兩份 kubeconfig 的 SHA-256 也一致。

### Troubleshooting

- 若 Ready 卡住，先看 Pod 事件與兩個容器的日誌。若兩個 HTTP 請求出現 404 或 503，先比對 `status.url`、HTTPRoute 父層狀態與 Envoy Service，而後確認 predictor 已 Ready。

  ```bash
  "${lab[@]}" -n lab2 get events --sort-by=.lastTimestamp
  "${lab[@]}" -n lab2 describe pods -l serving.kserve.io/inferenceservice=sklearn-iris
  "${lab[@]}" -n lab2 logs deployment/sklearn-iris-predictor -c storage-initializer
  "${lab[@]}" -n lab2 logs deployment/sklearn-iris-predictor -c kserve-container
  "${lab[@]}" -n lab2 describe httproute sklearn-iris
  ```

- 實際 V2 輸出為 `INT32`，測試依實測型別驗證。Envoy 存取日誌有短暫寫出延遲，測試以唯一 `User-Agent` 配對日誌並容許延遲。
- 部署初期的狀態更新衝突已由 controller 重試恢復。`VirtualServiceCRDNotFound` 是 Istio 路徑的警告，實際 Envoy HTTPRoute 已驗證。KServe 自動產生的預設 HPA 會因 Lab 尚未安裝 Metrics Server 而有 `FailedGetResourceMetric`，本階段的推論均成功，擴縮容留待後續階段。

## Phase 4｜Canary Deployment & Promotion

KServe v0.21.0 Standard 使用 `spec.canary`、`trafficPercent: 20` 與 Gateway API HTTPRoute。此處以 Envoy `upstream_host` 對照 EndpointSlice 與實際 Pod 來統計不同部署版本。Knative revisions 是 Cheat Sheet 所示的 Knative 路徑，本次 Standard 部署使用上述後端歸因。 [KServe v0.21 分流說明](https://kserve.github.io/website/blog/kserve-0.21-release#-canary-traffic-splitting-on-rawdeployment-httproutes) · [Envoy 存取日誌](https://gateway.envoyproxy.io/v1.9/tasks/observability/proxy-accesslog/#default-access-log)

### 佈署與測量

Stable baseline 保存在 [sklearn-iris.yaml](sklearn-iris.yaml)。[sklearn-iris-canary.yaml](sklearn-iris-canary.yaml) 保留既有 `model`，新增名為 `model-2` 的獨立 predictor。兩個 Deployment 均為 `1/1 Available`，`CanaryPredictorReady=True`。`sklearn-iris` 與 `sklearn-iris-predictor` 兩條 HTTPRoute 均為 80/20。`model` 與 `model-2` 的 `model.joblib` 實測 SHA-256 相同，本次驗證的是部署版本的流量分配與 Promotion。 [實測 SHA-256](evidence/04-canary-model-hashes.txt)

從 Phase 3 的 Stable 狀態重現時，使用以下 WSL Bash 指令。

```bash
cd ~/projects/mlops-lab2
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
lab=(kubectl --kubeconfig="$KUBECONFIG" --context=kind-kserve-lab2 --cache-dir="$PWD/.kube/cache")
"${lab[@]}" apply --server-side --dry-run=server -f sklearn-iris-canary.yaml
"${lab[@]}" apply --server-side -f sklearn-iris-canary.yaml
"${lab[@]}" -n lab2 rollout status deployment/sklearn-iris-model-2-predictor --timeout=120s
"${lab[@]}" -n lab2 get isvc sklearn-iris -o jsonpath='{.status.conditions}{"\n"}{.status.canaryStatuses}{"\n"}'
"${lab[@]}" -n lab2 get httproute sklearn-iris sklearn-iris-predictor -o yaml
```

以下為本次批次測試指令。重跑時若要保留本次原始證據，請另用檔名。測試以 `curl` 經 Envoy Gateway Service 送出 20 筆 V1 POST。每筆請求的唯一 `User-Agent` 配對一筆 Envoy `via_upstream` 記錄，再用 `upstream_host`、EndpointSlice、Pod UID 與 `storage-initializer` URI 辨識實際模型。腳本核對批次前後的路由和就緒端點一致，並保留逐筆回應與相符的日誌。 [canary-test.sh](canary-test.sh)

```bash
(set -o pipefail; bash canary-test.sh canary 20 | tee .kube/canary-replay.txt)
```

| 實測批次 | 總數 | 舊 Stable `model` | `model-2` | HTTP／傳輸失敗 | 無法歸因 |
|---|---:|---:|---:|---:|---:|
| 講義指定 Canary 批次 | 20 | 16（80%） | 4（20%） | 0 | 0 |
| Promotion 後重測 | 5 | 0（0%） | 5（100%） | 0 | 0 |

16:4 是此次觀測結果，20 筆抽樣可出現其他分布。Canary 批次中，`10.244.0.14:8080` 對應 Stable `model`，`10.244.0.15:8080` 對應 Canary `model-2`。各筆皆 HTTP 200，兩個後端都回傳 `[1,1]`。 [Canary 完整實測紀錄](evidence/04-canary-count.txt)

### Promotion

原本嘗試把 `predictor.name: model-2` 從 Canary 複製至正式 predictor。實際 v0.21.0 webhook 在 server dry run 拒絕 Standard 主 predictor 的 `name`。最終使用 [sklearn-iris-promote.yaml](sklearn-iris-promote.yaml)，將現有主 predictor 的 `storageUri` 改為官方 `model-2` 並移除 `spec.canary`。Kubernetes 完成滾動更新，原本的主 Service、HTTPRoute 名稱和 Host 保留。

```bash
"${lab[@]}" apply --server-side --dry-run=server -f sklearn-iris-promote.yaml
"${lab[@]}" apply --server-side -f sklearn-iris-promote.yaml
"${lab[@]}" -n lab2 rollout status deployment/sklearn-iris-predictor --timeout=120s
(set -o pipefail; bash canary-test.sh promoted 5 | tee .kube/promotion-replay.txt)
```

`sklearn-iris` 為 `READY=True`、`ActiveModelState=Loaded`。兩條 HTTPRoute 都只有 `sklearn-iris-predictor:80`，單一權重 `1` 承接 100%。此 Service 的唯一 Ready 端點 `10.244.0.16:8080` 由新 Pod 提供，初始化日誌顯示載入 `model-2`。Canary Deployment 已由 KServe 清理，舊版 Pod 已終止。經相同 Gateway／Host 重測的 5 筆請求皆 HTTP 200，全部對應到新 Pod。 [Promotion 完整實測紀錄](evidence/05-canary-promotion.txt)

### 排錯

- Canary `predictor.model.name` 為必要欄位，且此 runtime 需命名為 `kserve-container`。初次填入 `sklearn-iris` 導致 Pod mutator 找不到容器，修正後 Canary 載入 `model-2` 並就緒。公開推論模型名稱仍為 `sklearn-iris`。
- 本次 Standard InferenceService 的 `status.observedGeneration` 在 Promotion 後為 `2`，資源 generation 為 `4`。KServe 在 Standard 路徑取 Deployment 的 observedGeneration，因此 `kubectl wait --for=condition` 可能逾時。最後以 Deployment rollout、實際 Ready condition、模型載入 URI、兩條路由與資料面請求交叉驗證。 [KServe v0.21.0 狀態原始碼](https://raw.githubusercontent.com/kserve/kserve/v0.21.0/pkg/apis/serving/v1beta1/inference_service_status.go) · [kubectl 條件檢查原始碼](https://raw.githubusercontent.com/kubernetes/kubectl/v0.37.1/pkg/cmd/wait/condition.go)
- `test-cluster` 的容器 ID、啟動時間、重啟次數及 IP 與本階段開始前一致。預設與 Lab kubeconfig 的 SHA-256 均一致，預設 context 仍為 `kind-test-cluster`。

## Phase 5｜Autoscaling & Load Testing

KServe v0.21.0 Standard 原先已有一個指向 `Deployment/sklearn-iris-predictor` 的 HPA。`lab2` 缺少 `metrics.k8s.io`，所以 CPU 顯示 `<unknown>`。先核對實際 CRD 的 `minReplicas`、`maxReplicas`、`scaleMetric` 和 `scaleTarget`，再套用 [sklearn-iris-autoscaling.yaml](sklearn-iris-autoscaling.yaml)。HPA UID 與 InferenceService owner 保持一致，CPU request `100m`、limit `500m`、utilization target `50%`、副本範圍 `1–3`。模型仍載入 `model-2`，HTTPRoute 仍走同一個 Envoy Gateway。 [KServe v0.21 HPA](https://kserve.github.io/website/docs/model-serving/predictive-inference/autoscaling/hpa-autoscaler)

### Metrics Server v0.9.0 與 Lab kubelet TLS

官方相容矩陣的 v0.9.x 支援 Kubernetes v1.34+，涵蓋本 Lab 的 v1.36.4。官方 manifest 預設使用 InternalIP，初次部署日誌顯示 kubelet 憑證只有 `kserve-lab2-control-plane` DNS SAN，沒有 IP SAN。從 **Lab 節點**的公開 serving chain 擷取 CA，驗證 hostname 與即時 TLS 握手，接著只在 Metrics Server 掛載該 CA，並透過 Pod 的 `hostAliases` 解析節點 hostname。Metrics Server 到 kubelet 的憑證驗證保留，未使用 `--kubelet-insecure-tls`。官方 manifest 的 `APIService.insecureSkipTLSVerify: true` 僅作用於 API server 到 Metrics Server 的聚合連線，沿用發行檔設定。若 Lab 節點的 serving CA 或位址改變，需更新這份 Lab 專用信任設定。 [相容矩陣](https://github.com/kubernetes-sigs/metrics-server#compatibility-matrix) · [Metrics Server v0.9.0 發行檔](https://github.com/kubernetes-sigs/metrics-server/releases/tag/v0.9.0) · [Metrics Server FAQ](https://github.com/kubernetes-sigs/metrics-server/blob/master/FAQ.md)

```bash
cd ~/projects/mlops-lab2
export KUBECONFIG="$PWD/.kube/kserve-lab2.yaml"
lab=(kubectl --kubeconfig="$KUBECONFIG" --context=kind-kserve-lab2 --cache-dir="$PWD/.kube/cache")
d=.kube/phase5
mkdir -p "$d"
curl -fsSL https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml \
  -o "$d/metrics-server-v0.9.0.yaml"
printf '%s  %s\n' 1cec29a5267809306a2c6ec74a3e449abbb705b4a8beed0c8a1963910f72c79b \
  "$d/metrics-server-v0.9.0.yaml" | sha256sum --check
"${lab[@]}" apply --server-side -f "$d/metrics-server-v0.9.0.yaml"

node=kserve-lab2-control-plane
ip=$("${lab[@]}" get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
docker exec "$node" cat /var/lib/kubelet/pki/kubelet.crt > "$d/kubelet-public.pem"
awk '/BEGIN CERTIFICATE/ {n++} n==2' "$d/kubelet-public.pem" > "$d/kubelet-ca.pem"
openssl verify -CAfile "$d/kubelet-ca.pem" -verify_hostname "$node" "$d/kubelet-public.pem"
"${lab[@]}" -n kube-system create configmap lab-kubelet-serving-ca \
  --from-file=ca.pem="$d/kubelet-ca.pem" --dry-run=client -o yaml | "${lab[@]}" apply --server-side -f -
cat > "$d/metrics-server-kubelet-patch.yaml" <<EOF
spec:
  template:
    spec:
      hostAliases:
        - ip: "$ip"
          hostnames: ["$node"]
      volumes:
        - name: lab-kubelet-ca
          configMap:
            name: lab-kubelet-serving-ca
      containers:
        - name: metrics-server
          args:
            - --cert-dir=/tmp
            - --secure-port=10250
            - --kubelet-preferred-address-types=Hostname
            - --kubelet-use-node-status-port
            - --metric-resolution=15s
            - --kubelet-certificate-authority=/etc/lab-kubelet-ca/ca.pem
          volumeMounts:
            - name: lab-kubelet-ca
              mountPath: /etc/lab-kubelet-ca
              readOnly: true
EOF
"${lab[@]}" -n kube-system patch deploy metrics-server --type=strategic --patch-file "$d/metrics-server-kubelet-patch.yaml"
"${lab[@]}" -n kube-system rollout status deploy/metrics-server --timeout=150s
"${lab[@]}" wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
"${lab[@]}" get --raw /apis/metrics.k8s.io/v1beta1
"${lab[@]}" top nodes
"${lab[@]}" -n lab2 top pods
```

`kubectl top pods` 在 API Service 剛就緒時可能要等下一輪採樣。本次重查已取得 Pod CPU 和記憶體數值，HPA 的 `ScalingActive=True`、reason 為 `ValidMetricFound`。TLS 驗證回報 `Verify return code: 0 (ok)`。 [安裝後的真實基線](evidence/06-autoscaling-baseline.txt)

### HPA 與負載工具

```bash
"${lab[@]}" apply --server-side --dry-run=server -f sklearn-iris-autoscaling.yaml
"${lab[@]}" apply --server-side -f sklearn-iris-autoscaling.yaml
"${lab[@]}" -n lab2 rollout status deploy/sklearn-iris-predictor --timeout=150s
"${lab[@]}" -n lab2 get isvc,hpa,deploy,pod
"${lab[@]}" -n lab2 describe hpa sklearn-iris-predictor
```

`hey` 使用 Ubuntu Noble 官方 amd64 套件 `0.1.4-2ubuntu0.24.04.3`。比對 APT 套件索引 SHA-256 後只抽取 binary 到 `.kube/bin/hey`。該套件不支援 `-U`，初次啟動在傳送流量前即被旗標解析拒絕。修正後完成原定 30 秒批次。套件會覆寫自訂 User-Agent，因此後續腳本以 URL query 中的單次批次 ID 比對 Envoy access log。HTTP POST 仍送往相同的 V1 路徑。 [Ubuntu 發行紀錄](https://launchpad.net/ubuntu/+source/hey/0.1.4-2ubuntu0.24.04.3) · [hey v0.1.4 Header 實作](https://raw.githubusercontent.com/rakyll/hey/v0.1.4/hey.go)

```bash
version=0.1.4-2ubuntu0.24.04.3
archive=$(apt-cache show "hey=$version" | awk '$1=="Filename:" && !seen++ {print $2}')
checksum=$(apt-cache show "hey=$version" | awk '$1=="SHA256:" && !seen++ {print $2}')
curl -fsSL "https://archive.ubuntu.com/ubuntu/$archive" -o "$d/hey.deb"
printf '%s  %s\n' "$checksum" "$d/hey.deb" | sha256sum --check
mkdir -p .kube/bin
dpkg-deb --fsys-tarfile "$d/hey.deb" | tar -xOf - ./usr/bin/hey > "$d/hey"
install -m 0755 "$d/hey" .kube/bin/hey
```

[load-test.sh](load-test.sh) 需要基線為 1 個 Ready 副本且 HPA CPU 可用。腳本從 Gateway／HTTPRoute／InferenceService 查詢實際目標，在 WSL loopback 轉發 Envoy Service 的 80 埠，使用 TA 指定的 JSON 和 Host header。負載前後都做一次 gateway 推論。負載期間記錄 CPU、HPA Current／Desired、Deployment Current／Ready 與每個 Pod 狀態，結束後繼續觀察 HPA 降回基線。Kubernetes 預設 scale-down 穩定視窗為 300 秒。 [Kubernetes HPA 預設行為](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/#default-behavior)

```bash
bash load-test.sh 30s 20
# 等待 HPA 降回 1 個 Ready 副本，再跑補測。
bash load-test.sh 60s 20
```

### 實測結果（2026-11-20，UTC）

| 批次 | HTTP 200 | 其他 HTTP／傳輸錯誤 | 請求/秒 | 平均／p50／p95／p99 | Ready（負載前／負載中最高／全程最高／最後） |
|---|---:|---:|---:|---|---|
| TA 指定 30 秒 × 20 並行 | 15,902 | 0／0 | 528.97 | 37.8／20.1／73.9／78.5 ms | 1／1／3／1 |
| 補測 60 秒 × 20 並行 | 35,447 | 0／0 | 590.21 | 33.9／19.4／74.0／84.1 ms | 1／3／3／1 |

- **30 秒批次。** `13:52:11` HPA 記錄 `SuccessfulRescale`，原因為 CPU utilization 超過目標，將 Desired 提高至 3。新 Pod 在 `hey` 結束後才 Ready，`13:52:51` 觀察到 3 個 Ready，`13:57:56` HPA 自動降至 1。`hey` 的原始狀態分布只有 HTTP 200，無傳輸錯誤分布。原始腳本末尾的 assertion 來自 User-Agent 比對失敗，同一批次的 Envoy upstream HTTP 200 已從真實日誌補錄。 [TA 30 秒實測紀錄](evidence/07-autoscaling-ta-30s.txt)
- **60 秒補測。** 等第一批降至 1 個 Ready 後，只延長持續時間，保持 20 並行、相同 HPA、CPU 資源與輸入。`13:59:41` HPA 因 CPU 超標把 Desired 提至 3，`13:59:43` CPU 為 227%（227m），當時 Ready 為 1。`14:00:20` 負載仍在執行，已觀察到 3 個 Ready，CPU 為 501%（501m）。`14:05:42` HPA 自動降至 1，下一次採樣確認 1 個 Ready。Envoy 活躍日誌和 Lab 節點上的輪替日誌均有此批次 ID，紀錄含 `via_upstream`、HTTP 200 與實際後端位址。腳本現於負載期間擷取 Envoy 樣本，降低負載結束後因日誌輪替遺漏的機率。 [60 秒實測紀錄](evidence/08-autoscaling-60s.txt)
- **測試後。** `sklearn-iris` 持續 `READY=True`，仍使用 `model-2`，經相同 Gateway 的負載前後探測均為 HTTP 200，預測 `[1,1]`。Metrics Server 為 `1/1`，Metrics API 可用，最終 HPA CPU `2%/50%`，`ScalingActive=True`（`ValidMetricFound`）。舊 `test-cluster` 容器 ID、啟動時間、重啟次數及 IP 前後相同，兩份 kubeconfig 的 SHA-256 相同，預設 context 仍為 `kind-test-cluster`。

## Screenshots

五張 PNG 從 WSL Ubuntu 的 xterm 視窗擷取。畫面顯示各階段當時輸出的原始紀錄，保留原始時間戳與結果。完整 TXT 與逐筆紀錄也一併存於 `evidence/`。

| 檔案位置 | 畫面應顯示 |
|---|---|
| `evidence/01-isvc-ready.png` | `sklearn-iris`、`READY=True`、`Standard` 和 `1/1 Running` |
| `evidence/02-inference-v1.png` | V1 `:predict` POST、輸入、HTTP 200 和 `predictions: [1,1]` |
| `evidence/03-inference-v2.png` | V2 `/infer` POST、輸入、HTTP 200，以及 `INT32`、shape `[2]`、data `[1,1]` |
| `evidence/04-canary-count.png` | 80/20 權重、20 筆總數、Stable 16（80%）、Canary 4（20%）、失敗及無法歸因均為 0 |
| `evidence/05-autoscaling.png` | 60 秒／20 並行，負載中 Ready `1 → 3`、CPU 超標的 `SuccessfulRescale`、35,447 筆 HTTP 200，以及負載後回到 1 Ready |

![InferenceService Ready=True 與 predictor Running](evidence/01-isvc-ready.png)

![V1 推論 HTTP 200，預測為 1、1](evidence/02-inference-v1.png)

![V2 推論 HTTP 200，輸出 INT32，預測為 1、1](evidence/03-inference-v2.png)

![Canary 實測 20 筆，Stable 16 筆，Canary 4 筆](evidence/04-canary-count.png)

![Autoscaling 60 秒補測，負載中 Ready 從 1 增至 3](evidence/05-autoscaling.png)

可在專案目錄用以下指令重播五組真實輸出。

```bash
cd ~/projects/mlops-lab2
```

```bash
# 01-isvc-ready.png
sed -n '1,12p' evidence/01-isvc-ready.txt
```

```bash
# 02-inference-v1.png
sed '/^Envoy access log$/,$d' evidence/02-inference-v1.txt
```

```bash
# 03-inference-v2.png
sed '/^Envoy access log$/,$d' evidence/03-inference-v2.txt
```

```bash
# 04-canary-count.png
sed -n '1,11p' evidence/04-canary-count.txt
```

```bash
# 05-autoscaling.png
grep '^Command:' evidence/08-autoscaling-60s.txt
awk -F '\t' '
  $1 == "UTC" || $2 == "BEFORE" ||
  ($2 == "LOAD" && $5 > 1 && !desired++) ||
  ($2 == "LOAD" && $7 >= 2 && !ready++) ||
  ($2 == "AFTER" && $5 == 1 && $7 == 1 && !down++) {print}
' evidence/08-autoscaling-60s.txt | cut -f1-7
grep -E 'SuccessfulRescale|^HTTP 200 responses:' evidence/08-autoscaling-60s.txt
```

## Known Limitations

- TA 是否接受 Standard Mode 的 Envoy `upstream_host` 與 Pod 對照作為 Canary 證明仍待確認。20 次請求的 16／4 是此次樣本的觀測值，其他批次可有不同分布。
- `model` 與 `model-2` 的模型檔內容相同，兩版回傳相同的預測。部署版本由實際後端和模型 URI 辨識。
- Ready 擴容時間受 CPU 採樣、HPA reconciliation 和新 Pod 的啟動時間影響。30 秒批次證明了 HPA 提高 Desired，負載中 Ready 擴容由獨立的 60 秒批次證明。
- Metrics Server 的 CA 與 hostname 對應僅適用此 Lab kind 節點。節點 IP 或 serving CA 變更後需重新核對。

## Deliverables Checklist

| 交付項目 | 狀態 | 核對依據 |
|---|---|---|
| KServe InferenceService YAML | 已驗證 | [Standard sklearn baseline](sklearn-iris.yaml) 與 [Ready 輸出](evidence/01-isvc-ready.txt) |
| V1／V2 JSON 與推論腳本 | 已驗證 | [V1 資料](iris-input-v1.json)、[V2 資料](iris-input-v2.json) 的兩筆特徵相同。[腳本](test-inference.sh) 與兩份原始回應均證實 HTTP 200、預測 `[1,1]` |
| Canary Deployment YAML | 已驗證 | [Canary YAML](sklearn-iris-canary.yaml) 使用 KServe `spec.canary`，實測 HTTPRoute 權重 80/20 |
| 各版本實際 Canary 請求數 | 已驗證，TA 驗收方式待確認 | [20 筆原始紀錄](evidence/04-canary-count.txt) 可從 Envoy 與 Pod 對照重算 16／4 |
| Promotion YAML 與驗證 | 已驗證 | [Promotion YAML](sklearn-iris-promote.yaml) 與 [5 筆原始紀錄](evidence/05-canary-promotion.txt) 證明 `model-2` 單一後端 |
| Autoscaling YAML | 已驗證 | [Autoscaling YAML](sklearn-iris-autoscaling.yaml) 與 [Metrics／HPA 基線](evidence/06-autoscaling-baseline.txt) 證明 CPU 目標與副本設定 |
| hey 負載腳本 | 已檢查，兩批實測已驗證 | [負載腳本](load-test.sh) 通過語法檢查，數據由 [30 秒](evidence/07-autoscaling-ta-30s.txt) 與 [60 秒](evidence/08-autoscaling-60s.txt) 原始紀錄核對。最後調整的 Envoy 取樣時點尚未重跑整批負載 |
| README | 已驗證 | 安裝與重現指令、結果、排錯、已知限制，以及五個有效的相對圖片路徑 |
| 五張必要 PNG | 已驗證 | Screenshots 收錄五張 WSL 終端機擷取畫面及對應的原始證據 |
