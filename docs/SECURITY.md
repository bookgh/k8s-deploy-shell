# 安全模型

- 配置文件和节点清单仅作为数据读取，禁止 source 或 eval。
- SSH 必须启用 BatchMode 和 StrictHostKeyChecking，并使用专用 known_hosts 文件；连接前验证 SSH 用户、端口、连接超时、重试次数和退避范围。
- known_hosts 必须是可读的普通文件，拒绝符号链接，避免信任文件路径被意外重定向。
- 制品 HTTP 根目录只能包含非敏感、不可变的制品。
- 私钥和 kubeconfig 绝不能进入 Git、日志或 HTTP 根目录。
- 已有非空 CA/PKI 目录必须导致硬失败，禁止隐式覆盖。
- Kubernetes、etcd 和 front-proxy 根 CA 必须相互独立；ServiceAccount 签名密钥独立管理。
- 根 CA 有效期为 876024h，比 876000h 的叶证书多 24 小时。
- 根 CA、叶证书和 ServiceAccount 私钥文件权限为 0600，所在 PKI 目录权限为 0700；公开 HTTP 缓存必须使用独立目录。
- 叶证书私钥在安装节点生成，只能通过认证 SSH 通道分发；不得放入 Caddy HTTP 缓存。
- CFSSL 二进制必须锁定精确版本和 SHA256。证书有效期必须从实际签发证书的 NotAfter 验证，不得仅依据请求时长推断。
- 根 CA 私钥必须离线备份；外部备份流程尚未自动化。
- 除非显式配置，否则 SELinux 保持启用。关闭 SELinux 属于高风险安全决策。
- 防火墙规则不得全局清空或关闭。
- Dry-run 必须避免文件系统、网络、锁和系统状态副作用。
- etcd 恢复、成员变更、证书轮换、升级和数据删除必须使用单独审核并明确确认的操作流程。

SSH 包装器仅接受受限字符集的远端命令参数，不允许空格、Shell 元字符或未验证的动态命令片段进入远端命令字符串。SSH 参数在执行前进行独立校验，不能只依赖配置文件入口校验。

叶证书私钥仅通过启用严格 Host Key 校验的 SSH stdin 传输。远端将数据写入权限为 0600 的临时文件，校验 SHA256 后原子重命名；PKI 所在目录权限为 0700。私钥不通过 SCP/SFTP/rsync 或 Caddy HTTP 传输。根 CA 私钥和 admin 私钥始终保留在安装节点。

## M12 增量安全约束（2026-11-14）

- CLI `--dry-run` 必须设置独立 override 标志，不能被随后加载的 `DRY_RUN=false` 配置覆盖；即使与 `--apply` 同时出现，也必须零副作用。Nginx build/Worker proxy 已补齐该入口。
- etcd snapshot 属于远端写操作，必须显式 `--apply` 且 `DRY_RUN=false`；预览路径不得执行 SSH。快照命令使用本机 etcd 锁，并对远端命令按节点锁、组件锁的固定顺序获取非阻塞锁。
- M5–M7 远端安装器统一使用 `/run/lock/ks-deploy-shell-node.lock`，然后获取各自组件锁；冲突返回 75。所有新增嵌套锁必须保持该顺序，禁止反向获取。
- 节点锁是单节点互斥，不是跨节点分布式事务。多个安装节点同时操作同一集群、控制平面服务启动与 readiness 等跨命令临界区、SSH 断线后的集群级恢复语义仍须 fail-closed 设计和故障注入验证。
- Bats 合成测试和 GitHub Actions 不能证明 Rocky Linux 9 生产安全性；不得据此宣称 etcd 恢复、quorum 或生产验收完成。
