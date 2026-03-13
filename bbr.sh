cat > '/etc/sysctl.conf' << EOF
# 系统文件句柄优化
fs.file-max=1000000
fs.inotify.max_user_instances=65536

# 路由转发设置 (含 IPv6)
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv4.ip_local_port_range = 2000 65535
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.lo.forwarding = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0

# TCP 基础优化
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1

# TCP 连接回收与复用
net.ipv4.tcp_tw_reuse = 1
# 严禁开启 net.ipv4.tcp_tw_recycle，会导致 NAT 用户无法连接
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_max_syn_backlog = 131072

# 队列与高并发设置
net.core.netdev_max_backlog = 131072
net.core.somaxconn = 65535
net.ipv4.tcp_slow_start_after_idle = 0

# TCP 缓冲区设置 (适配高带宽，最大约 32MB)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# 拥塞控制与 BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 允许普通用户使用 ping
net.ipv4.ping_group_range = 0 2147483647
EOF

sysctl -p
