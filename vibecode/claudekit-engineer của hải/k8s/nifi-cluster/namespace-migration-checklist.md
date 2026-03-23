# NiFi Deployment & Namespace Migration Checklist

## Biến dùng trong lệnh

- `RELEASE=nifi-cluster`
- `CHART=./k8s/nifi-cluster`
- `VALUES=./k8s/nifi-cluster/values-override.yaml`
- `NS_OLD=<namespace-cu>`
- `NS_NEW=<namespace-moi>`

---

## A) Fresh Install (bất kỳ namespace nào)

### 1) Cài NiFiKop operator trước

```bash
# Thêm namespace vào k8s/nifikop/nifikop/values-override.yaml → namespaces: [nifi]
helm upgrade --install nifikop k8s/nifikop/nifikop \
  -f k8s/nifikop/nifikop/values-override.yaml -n nifi
kubectl wait --for=condition=ready pod -l release=nifikop -n nifi --timeout=60s
```

### 2) Deploy NiFi cluster

```bash
bash k8s/deploy-nifi-auth.sh          # namespace "nifi" (mặc định)
bash k8s/deploy-nifi-auth.sh nifi-1   # hoặc namespace tuỳ chọn
```

Script tự động:
- Tạo namespace nếu chưa có
- Xoá stale secrets (nifi-cluster-tls, nifi-cluster-controller, nifi-cluster-0-server-certificate)
- Generate bootstrap TLS cert (CA + server cert + JKS keystores)
- Tạo `nifi-cluster-tls` và `nifi-cluster-0-server-certificate` secrets
- Helm install nifi-cluster chart

### 3) Kiểm tra

```bash
kubectl get pods -n <namespace>
# Chờ pod 1/1 Running (khoảng 2-3 phút)
```

### Lưu ý quan trọng

- **NiFiKop v1.16.0 có bug bootstrap TLS**: operator tạo `nifi-cluster-0-server-certificate` chỉ có `password` key, không populate cert data → PEM decode error → không tạo được pod.
- **Workaround**: deploy script pre-seed cả 2 secrets (`nifi-cluster-tls` + `nifi-cluster-0-server-certificate`) với cert + JKS data trước khi helm install.
- **Yêu cầu**: openssl, keytool (JDK) phải có trên máy chạy script.
- **certManager.enabled** để `false` trong nifikop values — operator dùng internal PKI.

---

## B) Migrate NiFi + NiFiKop từ namespace A sang namespace B

### 1) Freeze trạng thái cluster cũ

- [ ] Dừng traffic ghi vào NiFi (nếu có upstream producers).
- [ ] Scale NiFi về 0:

```bash
kubectl scale nificluster $RELEASE --replicas=0 -n $NS_OLD
```

- [ ] Chờ pod về 0:

```bash
kubectl get pod -n $NS_OLD -w
```

### 2) Export hiện trạng trước migrate

- [ ] Export NifiCluster CR:

```bash
kubectl get nificluster $RELEASE -n $NS_OLD -o yaml > nificluster-before.yaml
```

- [ ] Export PVC/PV để đối chiếu:

```bash
kubectl get pvc -n $NS_OLD -o wide > pvc-before.txt
kubectl get pv -o wide > pv-before.txt
```

### 3) Verify dữ liệu NFS còn đủ (nếu dùng NFS)

- [ ] SSH vào NFS server, kiểm tra thư mục:
  - `/data/nfs/node-0/data`, `logs`, `flowfile-repo`, `content-repo`, `provenance-repo`
- [ ] Nếu nhiều node, kiểm tra thêm `node-1`, `node-2`, ...

### 4) Gỡ release ở namespace cũ

- [ ] Uninstall nifi-cluster:

```bash
helm uninstall $RELEASE -n $NS_OLD
```

- [ ] Uninstall nifikop (nếu cũng chuyển operator sang namespace mới):

```bash
helm uninstall nifikop -n $NS_OLD
```

- [ ] Xoá stale secrets + CRs (tránh block khi cài lại):

```bash
kubectl delete secrets --all -n $NS_OLD
kubectl delete nifiusers --all -n $NS_OLD 2>/dev/null
kubectl delete nificlusters --all -n $NS_OLD 2>/dev/null
```

- [ ] (Tuỳ chọn) Xoá namespace cũ nếu không cần nữa:

```bash
kubectl delete ns $NS_OLD
```

> **Lưu ý:** Nếu namespace bị stuck ở `Terminating`, xoá finalizers trên NifiCluster CR:
> ```bash
> kubectl patch nificlusters.nifi.konpyutaika.com $RELEASE -n $NS_OLD --type=merge -p '{"metadata":{"finalizers":[]}}'
> ```

### 5) Cài NiFiKop operator vào namespace mới

- [ ] Cập nhật `k8s/nifikop/nifikop/values-override.yaml`:

```yaml
namespaces:
  - <namespace-moi>   # ví dụ: nifi-1
```

- [ ] Tạo namespace mới + cài operator:

```bash
kubectl create namespace $NS_NEW
helm upgrade --install nifikop k8s/nifikop/nifikop \
  -f k8s/nifikop/nifikop/values-override.yaml -n $NS_NEW
kubectl wait --for=condition=ready pod -l release=nifikop -n $NS_NEW --timeout=60s
```

> **Lưu ý:** Operator chỉ tạo RBAC Role/RoleBinding cho các namespace trong `namespaces:` list.
> Nếu operator ở namespace khác (ví dụ vẫn ở `nifi`), phải thêm `$NS_NEW` vào list + `helm upgrade`.

### 6) Deploy NiFi cluster vào namespace mới

- [ ] Cập nhật `k8s/nifi-cluster/values-override.yaml`:
  - `singleUserConfiguration.secretRef.namespace` → `$NS_NEW`
  - `webProxyNodePorts.hosts` → cập nhật public IP nếu thay đổi

- [ ] Chạy deploy script:

```bash
bash k8s/deploy-nifi-auth.sh $NS_NEW
```

Script tự động xử lý:
- Xoá stale secrets (`nifi-cluster-tls`, `nifi-cluster-controller`, `nifi-cluster-0-server-certificate`)
- Generate bootstrap CA + server cert + JKS keystores
- Tạo 2 secrets cần thiết (workaround NiFiKop v1.16.0 TLS bootstrap bug)
- Helm install nifi-cluster chart

### 7) Kiểm tra pod + services

- [ ] Chờ pod lên `1/1 Running` (khoảng 2-3 phút):

```bash
kubectl get pods -n $NS_NEW -w
```

- [ ] Kiểm tra services:

```bash
kubectl get svc -n $NS_NEW
```

### 8) Kiểm tra binding PV/PVC (nếu dùng storageConfigs)

- [ ] Kiểm tra PVC phải `Bound`:

```bash
kubectl get pvc -n $NS_NEW
```

- [ ] Nếu PVC `Pending` do `claimRef` cũ, xoá claimRef trên PV:

```bash
kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

### 9) Smoke test

- [ ] Mở NiFi UI:

```bash
kubectl port-forward svc/nifi-cluster-ip 8443:8443 -n $NS_NEW
# Hoặc qua NodePort: https://<node-ip>:30443/nifi
```

- [ ] Login: `admin` / `NiFi-P0C-2026!`
- [ ] Xác nhận flow/repository cũ còn (nếu dùng NFS).
- [ ] Test persistence bằng cách restart pod:

```bash
kubectl delete pod -l app=nifi -n $NS_NEW
# Chờ pod mới lên, kiểm tra data vẫn còn
```

### 10) Rollback plan

- [ ] Nếu namespace mới fail:

```bash
helm uninstall $RELEASE -n $NS_NEW
helm uninstall nifikop -n $NS_NEW   # nếu operator cũng ở NS_NEW
kubectl delete ns $NS_NEW
```

- [ ] Cài lại ở namespace cũ:

```bash
# Cập nhật lại namespaces: [$NS_OLD] trong nifikop values
helm upgrade --install nifikop k8s/nifikop/nifikop \
  -f k8s/nifikop/nifikop/values-override.yaml -n $NS_OLD
bash k8s/deploy-nifi-auth.sh $NS_OLD
```

---

## Ghi chú quan trọng

- Với NFS externalVolumeConfigs, dữ liệu nằm trên NFS server → không mất khi đổi namespace.
- Với EBS storageConfigs (reclaimPolicy: Delete), PV bị xoá khi PVC bị xoá → **không an toàn cho migrate**.
- Điểm thường gây lỗi: `claimRef` còn trỏ namespace cũ; xử lý bằng patch ở bước 8.
- NiFiKop operator chỉ cần cài 1 lần — thêm namespace vào `namespaces:` list để watch nhiều namespace.
- Stale secrets (`nifi-cluster-tls`, `nifi-cluster-controller`, `nifi-cluster-0-server-certificate`) từ install cũ sẽ block operator reconciliation → deploy script tự xoá trước khi install.
