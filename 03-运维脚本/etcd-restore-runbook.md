# etcd 灾难恢复 Runbook
## 前置
- 有可用的备份文件（已用 snapshot status 校验过）
- 已确认集群真的无法恢复；已保留当前损坏的数据目录（不要删！可能还有救）
## 步骤
### 1. 停止 kubelet + etcd 容器（静态 Pod 的坑：只停 kubelet 不会停掉已运行的容器）
systemctl stop kubelet
crictl ps | grep etcd      # 找到 etcd 容器（名字形如 etcd-master）
crictl stop <etcd容器ID>   # ★ 必须手动停！etcd 进程还占着 /var/lib/etcd，不停掉后面 mv/restore 都会被干扰
### 2. 保留现场（关键！不要直接删）
mv /var/lib/etcd /var/lib/etcd.broken.$(date +%F-%H%M)
mkdir -p /var/lib/etcd
### 3. 执行恢复
/usr/local/bin/etcdctl snapshot restore /opt/etcd-backup/<备份文件名>.db \
  --name=master \
  --initial-cluster=master=https://192.168.113.140:2380 \
  --initial-advertise-peer-urls=https://192.168.113.140:2380 \
  --data-dir=/var/lib/etcd
### 4. 检查数据目录
ls -la /var/lib/etcd/member/
### 5. 启动 kubelet
systemctl start kubelet
### 6. 验证
sleep 30
kubectl get nodes
kubectl get pods -A
kubectl get deploy,svc -A
### 7. 恢复后必须做的事
- 重新做一次备份
- 记录本次事故（现象 → 根因 → 恢复过程 → 预防）
