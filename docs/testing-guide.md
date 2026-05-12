# テスト手順書

各フェーズを段階的に実行し、結果を確認するためのテスト手順。

---

## 前提

- `bash setup.sh` が完了していること
- `inventory/hosts.yml` と `inventory/group_vars/all.yml` が環境に合わせて編集済みであること

---

## Phase 0: 事前バリデーション

```bash
ansible-playbook playbooks/preflight.yml
```

### 確認項目

| チェック | 期待値 |
|---|---|
| Ansible バージョン | 2.15 以上 |
| vault.yml | 存在する |
| .vault_pass | 存在する |
| SSH 秘密鍵 | 存在する |
| Galaxy コレクション | community.general / kubernetes.core / ansible.posix がインストール済み |
| proxmoxer | import 成功 |
| Proxmox API | HTTP 200 |

### 失敗時

```bash
# vault 未作成の場合
bash setup.sh

# proxmoxer が無い場合
pip3 install proxmoxer requests

# コレクションが無い場合
ansible-galaxy collection install -r requirements.yml
```

---

## Phase 1: テンプレート作成

```bash
ansible-playbook playbooks/00_create_template.yml
```

### 確認コマンド

```bash
ssh root@192.168.1.10 "qm status 9000"
# 期待: status: stopped (テンプレートは stopped 状態)

ssh root@192.168.1.10 "qm config 9000"
# 期待: scsi0, ide2 (cloudinit), boot: order=scsi0 が存在
```

### 失敗時

```bash
# テンプレートを削除して再作成
ssh root@192.168.1.10 "qm destroy 9000"
ansible-playbook playbooks/00_create_template.yml
```

---

## Phase 2a: Control Plane VM 作成

```bash
ansible-playbook playbooks/01_create_cp_vm.yml
```

### 確認コマンド

```bash
ssh root@192.168.1.10 "qm status 201"
# 期待: status: running

ssh k8s@192.168.1.101 "hostname"
# 期待: k8s-cp01
```

---

## Phase 2b: Worker VM 作成

```bash
ansible-playbook playbooks/02_create_worker_vms.yml
```

### 確認コマンド

```bash
ssh root@192.168.1.10 "qm status 202; qm status 203"
# 期待: 両方 status: running

ssh k8s@192.168.1.102 "hostname"
# 期待: k8s-worker01

ssh k8s@192.168.1.103 "hostname"
# 期待: k8s-worker02
```

---

## Phase 2c: Storage VM 作成

```bash
ansible-playbook playbooks/03_create_storage_vm.yml
```

### 確認コマンド

```bash
ssh root@192.168.1.10 "qm status 204"
# 期待: status: running

ssh k8s@192.168.1.104 "hostname"
# 期待: k8s-storage01

ssh k8s@192.168.1.104 "df -h / | tail -1 | awk '{print \$2}'"
# 期待: 約 100G
```

---

## Phase 3: OS 共通セットアップ

```bash
ansible-playbook playbooks/04_common_setup.yml
```

### 確認コマンド

```bash
# swap が無効であること (全ノード)
ansible k8s_cluster -a "swapon --show"
# 期待: 出力なし (swap 無効)

# カーネルモジュールがロード済み
ansible k8s_cluster -a "lsmod | grep br_netfilter"
# 期待: br_netfilter の行が表示される

# containerd が稼働中
ansible k8s_cluster -a "systemctl is-active containerd"
# 期待: active

# kubeadm がインストール済み
ansible k8s_cluster -a "kubeadm version -o short"
# 期待: v1.31.x

# kubelet が enabled
ansible k8s_cluster -a "systemctl is-enabled kubelet"
# 期待: enabled
```

---

## Phase 4: Control Plane 初期化

```bash
ansible-playbook playbooks/05_init_control_plane.yml
```

### 確認コマンド

```bash
# CP ノードが Ready
ssh k8s@192.168.1.101 "kubectl get nodes"
# 期待: k8s-cp01  Ready  control-plane

# Calico Pod が Running
ssh k8s@192.168.1.101 "kubectl -n kube-system get pods | grep calico"
# 期待: calico-node-xxxxx  1/1  Running
#        calico-kube-controllers-xxxxx  1/1  Running

# CoreDNS が Running
ssh k8s@192.168.1.101 "kubectl -n kube-system get pods | grep coredns"
# 期待: coredns-xxxxx  1/1  Running (2 Pod)

# kubeadm join コマンドが生成されていること
ssh k8s@192.168.1.101 "sudo kubeadm token list"
# 期待: token が1行以上表示される
```

---

## Phase 5: Worker Join

```bash
ansible-playbook playbooks/06_join_workers.yml
```

### 確認コマンド

```bash
ssh k8s@192.168.1.101 "kubectl get nodes"
# 期待:
#   k8s-cp01       Ready  control-plane
#   k8s-worker01   Ready  worker
#   k8s-worker02   Ready  worker

ssh k8s@192.168.1.101 "kubectl get nodes --show-labels | grep worker"
# 期待: node-role.kubernetes.io/worker= ラベルが付与されている
```

---

## Phase 6: Storage Join

```bash
ansible-playbook playbooks/07_join_storage.yml
```

### 確認コマンド

```bash
ssh k8s@192.168.1.101 "kubectl get nodes"
# 期待:
#   k8s-cp01        Ready  control-plane
#   k8s-worker01    Ready  worker
#   k8s-worker02    Ready  worker
#   k8s-storage01   Ready  storage

# taint が付与されていること
ssh k8s@192.168.1.101 "kubectl describe node k8s-storage01 | grep Taint"
# 期待: node-role.kubernetes.io/storage=:NoSchedule

# iSCSI が稼働中
ssh k8s@192.168.1.104 "systemctl is-active iscsid"
# 期待: active
```

---

## Phase 7: Longhorn デプロイ

```bash
ansible-playbook playbooks/08_deploy_longhorn.yml
```

### 確認コマンド

```bash
# Longhorn Pod が全て Running
ssh k8s@192.168.1.101 "kubectl -n longhorn-system get pods"
# 期待: longhorn-manager, longhorn-driver-deployer 等が Running

# StorageClass が存在し default になっていること
ssh k8s@192.168.1.101 "kubectl get sc"
# 期待: longhorn (default)

# テスト PVC を作成して Bound を確認
ssh k8s@192.168.1.101 "kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF"

ssh k8s@192.168.1.101 "kubectl get pvc test-pvc"
# 期待: STATUS: Bound

# テスト PVC 削除
ssh k8s@192.168.1.101 "kubectl delete pvc test-pvc"
```

---

## Phase 8: Istio デプロイ

```bash
ansible-playbook playbooks/09_deploy_istio.yml
```

### 確認コマンド

```bash
# istiod が Running
ssh k8s@192.168.1.101 "kubectl -n istio-system get pods"
# 期待:
#   istiod-xxxxx                  1/1  Running
#   istio-ingressgateway-xxxxx    1/1  Running

# istiod のバージョン
ssh k8s@192.168.1.101 "kubectl -n istio-system get deployment istiod \
  -o jsonpath='{.spec.template.spec.containers[0].image}'"
# 期待: docker.io/istio/pilot:1.24.3

# Ingress Gateway サービス
ssh k8s@192.168.1.101 "kubectl -n istio-system get svc istio-ingressgateway"
# 期待: TYPE: LoadBalancer (EXTERNAL-IP は Pending でも正常)

# Istio サイドカー自動注入のテスト
ssh k8s@192.168.1.101 "kubectl create namespace test-istio"
ssh k8s@192.168.1.101 "kubectl label namespace test-istio istio-injection=enabled"
ssh k8s@192.168.1.101 "kubectl -n test-istio run nginx --image=nginx --restart=Never"
ssh k8s@192.168.1.101 "sleep 10 && kubectl -n test-istio get pod nginx -o jsonpath='{.spec.containers[*].name}'"
# 期待: nginx istio-proxy (コンテナが2つ)

# テスト namespace 削除
ssh k8s@192.168.1.101 "kubectl delete namespace test-istio"
```

---

## 一括実行 (全フェーズ)

```bash
make deploy
```

上記 Phase 0〜8 の全確認コマンドを順に実行して最終検証する。

---

## Makefile 経由の個別実行

```bash
make phase N=00   # Phase 1: テンプレート作成
make phase N=01   # Phase 2a: CP VM
make phase N=02   # Phase 2b: Worker VM
make phase N=03   # Phase 2c: Storage VM
make phase N=04   # Phase 3: OS 共通セットアップ
make phase N=05   # Phase 4: Control Plane 初期化
make phase N=06   # Phase 5: Worker Join
make phase N=07   # Phase 6: Storage Join
make phase N=08   # Phase 7: Longhorn
make phase N=09   # Phase 8: Istio
```

---

## クリーンアップ (テスト完了後の環境削除)

```bash
# 全 VM を停止・削除 (Proxmox 上で実行)
ssh root@192.168.1.10 "for id in 201 202 203 204; do qm stop \$id; qm destroy \$id; done"

# テンプレートも削除する場合
ssh root@192.168.1.10 "qm destroy 9000"
```
