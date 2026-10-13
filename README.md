# Kubernetes 运维实践笔记（个人学习集群）

## 集群概况
- 架构：kubeadm v1.30.0，1 控制面 + 3 工作节点（CentOS 7.9），4 节点
- 容器运行时：containerd 1.6.33
- CNI：Flannel v0.28.9（VXLAN，Pod 网段 10.244.0.0/16，每节点 /24）
- 存储：NFS + nfs-subdir-external-provisioner（StorageClass 动态供给）
- 监控：kube-prometheus-stack（Prometheus + Grafana + Alertmanager + KSM）
- 入口：ingress-nginx（baremetal 模式）

## 目录
| 目录 | 内容 |
|---|---|
| 01-搭建记录 | kubeadm 集群搭建全过程 |
| 02-巡检 | 巡检脚本 + 巡检清单 |
| 03-运维脚本 | 集群启停、etcd 备份与恢复 Runbook |
| 04-故障记录 | 故障排查记录（现象/排查/根因/修复/预防） |
| 05-监控告警 | Prometheus 配置 + 告警规则 |
| 06-存储 | PV/PVC + StorageClass 配置 |
| 07-部署清单 | 应用部署 YAML |

## 关键实践
- etcd 每日自动备份（snapshot status 校验）+ 恢复 Runbook
- 三层指标采集：node_exporter / cAdvisor / kube-state-metrics
- 告警链路验证：故意触发 TargetDown，确认 firing + resolved
- 根分区 17G 在线扩容至 37G（LVM + XFS）
