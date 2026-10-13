#!/bin/bash
###############################################################
# check4.sh - 集群进度总检（健康巡检 + 学习进度）4 节点版
# ------------------------------------------------------------
# 适用集群：master=192.168.113.140  node1=141  node2=142  node3=143
# 用法（在 master 上以 root 执行）：
#   chmod +x check4.sh && ./check4.sh
#   ./check4.sh | tee check4-$(date +%F-%H%M).txt    # 屏幕显示 + 留档
# 说明：
#   - 第一部分 = 集群健康（沿用 check3.sh 的 14 项，只读）
#   - 第二部分 = 学习进度（对照 01-学习指南 Day 1~13，12 个模块 + 手动确认项）
#   - 全程只读，不会修改集群任何东西；可随时重复执行
#   - 要求 master 已配置到 141/142/143 的 SSH 免密
###############################################################

MASTER_IP="192.168.113.140"
ALL_IPS=("192.168.113.140" "192.168.113.141" "192.168.113.142" "192.168.113.143")
ALL_NAMES=("master" "node1" "node2" "node3")

OK="[ OK ]"; WARN="[WARN]"; ERR="[ERR ]"

# 在远端节点执行命令（需 SSH 免密）
remote() {
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$1" "$2" 2>/dev/null
}

echo "=============================================================="
echo " 进度总检  时间: $(date '+%F %T')   巡检主机: $(hostname)"
echo " 节点: ${ALL_NAMES[*]}"
echo "  IP : ${ALL_IPS[*]}"
echo "=============================================================="

# ================================================================
# 第一部分：集群健康（沿用 check3.sh 14 项）
# ================================================================

# ---------- ① 服务开机自启（master 本机） ----------
echo
echo "① 服务开机自启（master）—— 你踩过 kubelet disabled 的坑"
for svc in containerd kubelet docker; do
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
    printf "   %-12s enabled=%-10s active=%s\n" "$svc" \
      "$(systemctl is-enabled $svc 2>/dev/null || echo 未知)" \
      "$(systemctl is-active $svc 2>/dev/null || echo 未知)"
  else
    printf "   %-12s 未安装\n" "$svc"
  fi
done

# ---------- ② 节点状态 ----------
echo
echo "② 节点状态"
kubectl get nodes -o wide 2>/dev/null || echo "   $ERR 无法连接 apiserver（检查 kubelet / 静态 Pod / 网络）"

# ---------- ③ 节点 Conditions ----------
echo
echo "③ 节点 Conditions（Ready 之外还要看 Pressure 是否 False）"
for n in "${ALL_NAMES[@]}"; do
  echo "   [$n]"
  kubectl describe node "$n" 2>/dev/null \
    | sed -n '/^Conditions:/,/^Addresses:/p' \
    | grep -E 'Ready|NetworkUnavailable|MemoryPressure|DiskPressure|PIDPressure' \
    | sed 's/^/      /'
done

# ---------- ④ 非 Running 的 Pod ----------
echo
echo "④ 非 Running/Completed 的 Pod"
P=$(kubectl get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed')
[ -z "$P" ] && echo "   $OK 无异常 Pod" || echo "$P"

# ---------- ⑤ Pod 重启次数 Top5 ----------
echo
echo "⑤ Pod 重启次数 Top5（重启次数是最容易忽略的信号）"
kubectl get pods -A --no-headers 2>/dev/null | sort -k5 -rn | head -5

# ---------- ⑥ 最近 Warning 事件 ----------
echo
echo "⑥ 最近 Warning 事件（最后 10 条）"
E=$(kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -10)
[ -z "$E" ] && echo "   $OK 无 Warning" || echo "$E"

# ---------- ⑦ 节点基础环境（4 台） ----------
echo
echo "⑦ 节点基础环境（SELinux / swap / firewalld / 内核参数 / br_netfilter）"
env_report() {
  printf "      SELinux             : %s\n" "$(getenforce 2>/dev/null)"
  printf "      swap 开启数          : %s\n" "$(swapon --show 2>/dev/null | wc -l)"
  printf "      firewalld           : %s\n" "$(systemctl is-active firewalld 2>/dev/null)"
  printf "      ip_forward          : %s\n" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  printf "      bridge-nf-call-ipt  : %s\n" "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null)"
  printf "      br_netfilter 模块   : %s (1=已加载)\n" "$(lsmod 2>/dev/null | grep -c '^br_netfilter')"
}
for i in 0 1 2 3; do
  ip="${ALL_IPS[$i]}"; name="${ALL_NAMES[$i]}"
  echo "   [$name $ip]"
  if [ "$ip" = "$MASTER_IP" ]; then
    env_report
  else
    remote "$ip" "$(declare -f env_report); env_report" || echo "   $ERR 无法连接 $ip（检查 SSH 免密）"
  fi
done

# ---------- ⑧ 磁盘 / 内存（4 台） ----------
echo
echo "⑧ 磁盘 / 内存（阈值：磁盘<80%  内存可用>300M）"
disk_report() {
  printf "      磁盘 / : %s\n" "$(df -h / | tail -1)"
  free -h | head -2 | sed 's/^/      /'
}
for i in 0 1 2 3; do
  ip="${ALL_IPS[$i]}"; name="${ALL_NAMES[$i]}"
  echo "   [$name $ip]"
  if [ "$ip" = "$MASTER_IP" ]; then
    disk_report
  else
    remote "$ip" "$(declare -f disk_report); disk_report" || echo "   $ERR 无法连接 $ip"
  fi
done

# ---------- ⑨ kubeadm 证书 ----------
echo
echo "⑨ kubeadm 证书剩余时间（<30 天需续期 kubeadm certs renew all）"
kubeadm certs check-expiration 2>/dev/null | grep -E 'admin.conf|apiserver |^ca ' | head -4 \
  || echo "   $WARN kubeadm 不可用或证书查询失败"

# ---------- ⑩ CNI 子网文件（4 台） ----------
echo
echo "⑩ /run/flannel/subnet.env（tmpfs 重启即丢；缺失→新 Pod 建不了网络沙箱）"
cni_report() {
  if [ -f /run/flannel/subnet.env ]; then
    cat /run/flannel/subnet.env
  else
    echo "   $ERR 缺失！/run/flannel/subnet.env 不存在"
  fi
}
for i in 0 1 2 3; do
  ip="${ALL_IPS[$i]}"; name="${ALL_NAMES[$i]}"
  echo "   [$name $ip]"
  if [ "$ip" = "$MASTER_IP" ]; then
    cni_report
  else
    remote "$ip" "$(declare -f cni_report); cni_report" || echo "   $ERR 无法连接 $ip"
  fi
done

# ---------- ⑪ 资源用量 ----------
echo
echo "⑪ 资源用量（需要 metrics-server）"
kubectl top nodes 2>/dev/null || echo "   $WARN Metrics API 不可用（metrics-server 未装或异常）"

# ---------- ⑫ 旧监控组件（Day 2 切 stack 后应停用） ----------
echo
echo "⑫ 宿主机旧监控（切换 kube-prometheus-stack 后应为 inactive）"
for svc in prometheus node_exporter alertmanager alert-webhook; do
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}.service"; then
    printf "   %-16s active=%s\n" "$svc" "$(systemctl is-active $svc 2>/dev/null || echo 未知)"
  fi
done
docker ps --format '{{.Names}}  {{.Status}}' 2>/dev/null | grep -i grafana \
  && echo "   (grafana 以 docker 容器运行)" || echo "   $WARN 未发现 grafana 容器"

# ---------- ⑬ etcd 备份 ----------
echo
echo "⑬ etcd 备份（最近 7 天内必须有）"
BAKDIRS="/data/etcd-backup /opt/etcd-backup"
CNT=$(ls $BAKDIRS/*.db 2>/dev/null | wc -l)
echo "   备份数量: ${CNT:-0}"
if [ "${CNT:-0}" -gt 0 ] 2>/dev/null; then
  ls -lh $BAKDIRS/*.db 2>/dev/null | tail -3 | sed 's/^/   /'
else
  echo "   $ERR 从未备份！立即做 01 §3.1"
fi
crontab -l 2>/dev/null | grep -qiE 'etcd|backup' \
  && echo "   定时任务: 已配置" || echo "   $WARN 无 etcd 备份定时任务"
NEWEST=$(ls -t $BAKDIRS/*.db 2>/dev/null | head -1)
if [ -n "$NEWEST" ]; then
  echo "   最新备份校验（$NEWEST）:"
  if [ -x /usr/local/bin/etcdctl ]; then
    /usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      snapshot status "$NEWEST" -w table 2>/dev/null | sed 's/^/     /' \
      || echo "   $WARN 校验失败，需手动检查"
  else
    CID=$(crictl ps --name etcd -q 2>/dev/null | head -1)
    if [ -n "$CID" ]; then
      crictl exec "$CID" etcdctl snapshot status "$NEWEST" -w table 2>/dev/null | sed 's/^/     /' \
        || echo "   $WARN 校验失败，需手动检查"
    else
      echo "   $WARN 未找到 etcd 容器，跳过校验（用宿主机 etcdctl 手动验）"
    fi
  fi
fi

# ---------- ⑭ 四节点互通与基础信息 ----------
echo
echo "⑭ 四节点互通与基础信息"
node_info() {
  printf "      主机名=%-8s 核数=%s  内存=%s  磁盘/=%s(已用%s)\n" \
    "$(hostname)" "$(nproc)" "$(free -h | awk '/^Mem:/{print $2}')" \
    "$(df -h / | tail -1 | awk '{print $2}')" "$(df -h / | tail -1 | awk '{print $5}')"
}
for i in 0 1 2 3; do
  ip="${ALL_IPS[$i]}"; name="${ALL_NAMES[$i]}"
  echo "   [$name $ip]"
  if [ "$ip" = "$MASTER_IP" ]; then
    node_info
  else
    remote "$ip" "$(declare -f node_info); node_info" || echo "   $ERR 无法连接 $ip（SSH 不通或免密未配）"
  fi
done

# ================================================================
# 第二部分：学习进度（对照 01-学习指南 Day 1~13）
# ================================================================
echo
echo "=============================================================="
echo " 学习进度总检（对照 01-学习指南 Day 1~13）"
echo "=============================================================="

DONE="[完成]"; TODO="[未做]"; PART="[部分]"
M_DONE=0; M_PART=0; M_TODO=0

mod() { # mod <D|P|T> <名称> <详情>
  case "$1" in
    D) M_DONE=$((M_DONE+1)); printf "  %s %-22s %s\n" "$DONE" "$2" "$3" ;;
    P) M_PART=$((M_PART+1)); printf "  %s %-22s %s\n" "$PART" "$2" "$3" ;;
    T) M_TODO=$((M_TODO+1)); printf "  %s %-22s %s\n" "$TODO" "$2" "$3" ;;
  esac
}

# ---------- Day 1 ----------
echo
echo "--- Day 1：etcd 自动备份 + metrics-server ---"

if crontab -l 2>/dev/null | grep -qiE 'etcd|backup'; then
  mod D "M1 etcd 定时备份" "crontab 已配置"
else
  mod T "M1 etcd 定时备份" "无定时任务（01 §3.1，最优先）"
fi

if kubectl -n kube-system get deploy metrics-server --no-headers 2>/dev/null | grep -q metrics-server; then
  TOP=$(kubectl top nodes 2>/dev/null | grep -c '^[a-z]')
  if [ "$TOP" -gt 0 ]; then
    mod D "M2 metrics-server" "已装且 kubectl top 有数据"
  else
    mod P "M2 metrics-server" "已装但 top 无数据（查 --kubelet-insecure-tls）"
  fi
else
  mod T "M2 metrics-server" "未安装（01 §3.3）"
fi

# ---------- Day 2 ----------
echo
echo "--- Day 2：kube-prometheus-stack + 告警 ---"

if command -v helm >/dev/null 2>&1; then
  mod D "M3 Helm" "已安装 $(helm version --short 2>/dev/null)"
else
  mod T "M3 Helm" "未安装（01 §Day2 第2步）"
fi

STACK_PODS=$(kubectl -n monitoring get pods --no-headers 2>/dev/null)
if [ -z "$STACK_PODS" ]; then
  if kubectl get ns monitoring --no-headers 2>/dev/null | grep -q monitoring; then
    mod T "M4 stack 部署" "monitoring ns 存在但无 Pod"
  else
    mod T "M4 stack 部署" "未安装（01 §Day2 第4步）"
  fi
else
  RUN=$(echo "$STACK_PODS" | awk '{print $3}' | grep -c Running)
  TOT=$(echo "$STACK_PODS" | wc -l)
  if [ "$RUN" -eq "$TOT" ]; then
    mod D "M4 stack 部署" "$TOT/$TOT Running"
  else
    mod P "M4 stack 部署" "$RUN/$TOT Running，有异常 Pod"
  fi
fi

# M5 直接按 DaemonSet 检查（不依赖 label 拼写；stack 的 ds 名含 prometheus-node-exporter）
NE_DS=$(kubectl -n monitoring get ds --no-headers 2>/dev/null | grep -i 'node-exporter')
if [ -z "$NE_DS" ]; then
  mod T "M5 node-exporter" "未发现（stack 未装）"
else
  NE_D=$(echo "$NE_DS" | awk '{print $2}')
  NE_R=$(echo "$NE_DS" | awk '{print $4}')
  if [ "$NE_R" -eq "$NE_D" ] && [ "$NE_R" -gt 0 ]; then
    mod D "M5 node-exporter" "$NE_R/$NE_D 台 Running"
  elif [ "$NE_R" -gt 0 ]; then
    mod P "M5 node-exporter" "$NE_R/$NE_D 台 Running（应 $NE_D）"
  else
    mod T "M5 node-exporter" "$NE_R/$NE_D Running，Pod 未 Ready"
  fi
fi

if kubectl get ns monitoring --no-headers 2>/dev/null | grep -q monitoring \
   && kubectl -n monitoring get secret 2>/dev/null | grep -qi alertmanager; then
  if kubectl -n monitoring get secret alertmanager-kube-prometheus-stack-alertmanager \
       -o jsonpath='{.data.alertmanager\.yaml}' 2>/dev/null | base64 -d 2>/dev/null | grep -q 'webhook'; then
    mod D "M6 告警 webhook" "receiver 已配置"
  else
    mod T "M6 告警 webhook" "未配置（01 §Day2 第7步）"
  fi
else
  mod T "M6 告警 webhook" "alertmanager 不存在，无法检查"
fi

NPS=$(kubectl -n monitoring get svc --no-headers 2>/dev/null | awk '{print $2}' | grep -c NodePort)
if [ "$NPS" -ge 3 ]; then
  mod D "M7 三服务 NodePort" "grafana/prometheus/alertmanager 均已暴露"
elif [ "$NPS" -gt 0 ]; then
  mod P "M7 三服务 NodePort" "只有 $NPS 个 NodePort（应 3 个）"
else
  mod T "M7 三服务 NodePort" "无 NodePort（stack 未装）"
fi

# ---------- Day 3 ----------
echo
echo "--- Day 3：nginx 规范化 + 实验 + Ingress ---"

if kubectl -n default get deploy nginx-demo --no-headers 2>/dev/null | grep -q nginx-demo; then
  PROBE=$(kubectl -n default get deploy nginx-demo -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
  RES=$(kubectl -n default get deploy nginx-demo -o jsonpath='{.spec.template.spec.containers[0].resources.limits}' 2>/dev/null)
  if [ -n "$PROBE" ] && [ -n "$RES" ]; then
    mod D "M8 nginx-demo 规范化" "探针 + resources 已配"
  else
    mod P "M8 nginx-demo 规范化" "已部署但缺探针或 resources（01 §5.1）"
  fi
else
  mod T "M8 nginx-demo 规范化" "未创建（01 §5.1）"
fi

ING_NS=$(kubectl get ns ingress-nginx --no-headers 2>/dev/null)
ING_CNT=$(kubectl get ingress -A --no-headers 2>/dev/null | wc -l)
if [ -n "$ING_NS" ]; then
  if [ "$ING_CNT" -gt 0 ]; then
    mod D "M9 Ingress" "controller 已装 + $ING_CNT 条规则"
  else
    mod P "M9 Ingress" "controller 已装但无规则（01 §5.7 ⑥⑦）"
  fi
else
  mod T "M9 Ingress" "未安装（01 §5.7，可选）"
fi

# ---------- Day 4~5 ----------
echo
echo "--- Day 4~5：etcd 恢复演练 + 存储 ---"

if [ -f /root/k8s/etcd-restore-runbook.md ]; then
  mod D "M10 etcd 恢复 Runbook" "已编写（/root/k8s/etcd-restore-runbook.md）"
else
  mod T "M10 etcd 恢复 Runbook" "未写（01 §6.1 第⑤步）"
fi

PVC_ST=$(kubectl -n default get pvc pvc-demo --no-headers 2>/dev/null | awk '{print $2}')
if [ "$PVC_ST" = "Bound" ]; then
  mod D "M11 PV/PVC" "pvc-demo 已 Bound"
elif [ -n "$PVC_ST" ]; then
  mod P "M11 PV/PVC" "状态=$PVC_ST（应 Bound，查 01 §6.2 四原因）"
else
  mod T "M11 PV/PVC" "未创建（01 §6.2）"
fi

if kubectl get sc --no-headers 2>/dev/null | grep -q 'nfs-client (default)'; then
  mod D "M12 NFS StorageClass" "nfs-client 已设为默认 SC"
elif kubectl get sc nfs-client --no-headers 2>/dev/null | grep -q nfs-client; then
  mod P "M12 NFS StorageClass" "存在但未设默认（01 §6.3）"
else
  mod T "M12 NFS StorageClass" "未部署（01 §6.3）"
fi

# ---------- Day 6~10 ----------
echo
echo "--- Day 6~10：故障演练（5 段式记录） ---"

FCOUNT=$(( $(ls /root/k8s/*.md 2>/dev/null | grep -viE 'runbook' | wc -l) \
         + $(ls /root/k8s-ops-notes/04-故障记录/*.md 2>/dev/null | wc -l) ))
if [ "$FCOUNT" -gt 0 ]; then
  mod D "M13 故障记录" "已写 $FCOUNT 份记录（含真实案例）"
else
  mod T "M13 故障记录" "未写 5 段式记录（01 §第七部分）"
fi

# ---------- Day 11~13 ----------
echo
echo "--- Day 11~13：CI/CD + GitHub ---"

if [ -d /root/k8s-ops-notes/.git ]; then
  mod D "M14 GitHub 仓库" "本地仓库已建"
else
  mod T "M14 GitHub 仓库" "未建（01 §8.1）"
fi

if kubectl -n default get sa ci-deployer --no-headers 2>/dev/null | grep -q ci-deployer; then
  if kubectl -n default get secret ci-deployer-token --no-headers 2>/dev/null | grep -q ci-deployer-token; then
    mod D "M15 CI ServiceAccount" "ci-deployer + token 已建"
  else
    mod P "M15 CI ServiceAccount" "SA 已建但 token Secret 未建（01 §8.2）"
  fi
else
  mod T "M15 CI ServiceAccount" "未创建（01 §8.2）"
fi

# ---------- 手动确认项 ----------
echo
echo "--- 需手动确认（脚本无法从 master 检查） ---"
echo "  [手动] Windows 上是否已有一份 etcd 备份副本（3-2-1 原则）"
echo "  [手动] 03-面试素材.md 是否已按 01 §9.2 更新（简历条目对应真实文件）"
echo "  [手动] GitHub Secrets 是否已配置 KUBE_TOKEN / KUBE_SERVER"
echo "  [手动] 简历是否已投递 ≥10 家（01 §9.3）"

# ---------- 汇总与建议 ----------
echo
echo "=============================================================="
echo " 进度汇总：完成 $M_DONE 项 / 部分 $M_PART 项 / 未做 $M_TODO 项（共 $((M_DONE+M_PART+M_TODO)) 项）"
echo "--------------------------------------------------------------"
echo " 下一步建议（按 01 指南优先级，只列未完成中最关键的）："
SUGGEST=""
[ $M_TODO -ge 1 ] && SUGGEST+="① etcd crontab（§3.1）→ metrics-server（§3.3）→ stack（Day2）→ 存储（Day4-5）→ 故障记录（Day6-10）"
echo "  $SUGGEST"
[ $M_DONE -ge 11 ] && echo "  已接近全部完成：只剩手动确认项 + 面试冲刺（第九部分）"
[ $M_DONE -ge 8 ] && [ $M_DONE -lt 11 ] && echo "  进度过半：优先补齐未做模块，故障演练（M13）是面试权重最高的一块"
[ $M_DONE -lt 8 ] && echo "  当前处于 Day1~Day5 阶段：按 01 顺序推进，不要跳步"
echo "=============================================================="
echo
echo " 把本结果完整发回分析（含两部分输出）。"
echo "=============================================================="
