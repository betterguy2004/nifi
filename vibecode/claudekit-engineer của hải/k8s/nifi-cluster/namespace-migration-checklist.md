# Namespace Migration Checklist (Giữ lại NFS Storage cũ)

## Biến dùng trong lệnh

- `RELEASE=nifi-cluster`
- `CHART=./k8s/nifi-cluster`
- `VALUES=./k8s/nifi-cluster/values-override.yaml`
- `NS_OLD=<namespace-cu>`
- `NS_NEW=<namespace-moi>`

## 1) Freeze trạng thái cluster cũ

- [ ] Dừng traffic ghi vào NiFi (nếu có upstream producers).
- [ ] Scale NiFi về 0:

```bash
kubectl scale nificluster $RELEASE --replicas=0 -n $NS_OLD
```

- [ ] Chờ pod về 0:

```bash
kubectl get pod -n $NS_OLD -w
```

## 2) Export hiện trạng trước migrate

- [ ] Export NifiCluster CR:

```bash
kubectl get nificluster $RELEASE -n $NS_OLD -o yaml > nificluster-before.yaml
```

- [ ] Export PVC/PV để đối chiếu:

```bash
kubectl get pvc -n $NS_OLD -o wide > pvc-before.txt
kubectl get pv -o wide > pv-before.txt
kubectl get pv -o yaml > pv-before.yaml
```

## 3) Verify dữ liệu NFS còn đủ

- [ ] Kiểm tra thư mục NFS node/repo:
  - `/data/nfs/node-0/data`
  - `/data/nfs/node-0/logs`
  - `/data/nfs/node-0/flowfile-repo`
  - `/data/nfs/node-0/content-repo`
  - `/data/nfs/node-0/provenance-repo`
- [ ] Nếu nhiều node, kiểm tra thêm `node-1`, `node-2`, ...

## 4) Gỡ release ở namespace cũ

- [ ] Uninstall chart:

```bash
helm uninstall $RELEASE -n $NS_OLD
```

- [ ] Kiểm tra PV còn tồn tại:

```bash
kubectl get pv | grep $RELEASE
```

## 5) Cài release vào namespace mới

- [ ] Tạo namespace mới:

```bash
kubectl create namespace $NS_NEW
```

- [ ] Cài lại chart (giữ nguyên release name để claim naming nhất quán):

```bash
helm install $RELEASE $CHART -f $VALUES -n $NS_NEW
```

## 6) Kiểm tra binding PV/PVC sau migrate

- [ ] Kiểm tra PVC ở namespace mới phải `Bound`:

```bash
kubectl get pvc -n $NS_NEW
```

- [ ] Kiểm tra PV map đúng claim namespace mới:

```bash
kubectl get pv
kubectl describe pv <pv-name>
```

## 7) Nếu PVC Pending do claimRef cũ

- [ ] Xóa `spec.claimRef` trên PV bị kẹt rồi để PVC bind lại:

```bash
kubectl patch pv <pv-name> --type=json -p='[{"op":"remove","path":"/spec/claimRef"}]'
```

- [ ] Kiểm tra lại PVC:

```bash
kubectl get pvc -n $NS_NEW
```

## 8) Smoke test sau migrate

- [ ] Scale lên và kiểm tra pod running:

```bash
kubectl get pods -n $NS_NEW
```

- [ ] Mở NiFi UI và xác nhận flow/repository cũ còn.
- [ ] Test vòng đời scale `0 -> 1` để xác nhận persistence:

```bash
kubectl scale nificluster $RELEASE --replicas=0 -n $NS_NEW
kubectl scale nificluster $RELEASE --replicas=1 -n $NS_NEW
```

## 9) Rollback plan (nếu cần)

- [ ] Nếu namespace mới không lên được, uninstall ở namespace mới:

```bash
helm uninstall $RELEASE -n $NS_NEW
```

- [ ] Install lại ở namespace cũ với cùng values:

```bash
helm install $RELEASE $CHART -f $VALUES -n $NS_OLD
```

---

## Ghi chú quan trọng

- Với static PV + NFS path cố định (`/data/nfs/node-<id>/<storage-name>`), dữ liệu nằm trên NFS nên không mất khi đổi namespace.
- Điểm thường gây lỗi là `claimRef` còn trỏ namespace cũ; xử lý bằng patch ở bước 7.
- Access mode `ReadWriteOnce` vẫn ổn vì mỗi node dùng PVC/PV riêng, không overlap dữ liệu.
