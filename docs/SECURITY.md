# 安全模型

- 配置文件和节点清单仅作为数据读取，禁止 source 或 eval。
- SSH 必须启用 BatchMode 和 StrictHostKeyChecking，并使用专用 known_hosts 文件。
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

叶证书私钥仅通过启用严格 Host Key 校验的 SSH stdin 传输。远端将数据写入权限为 0600 的临时文件，校验 SHA256 后原子重命名；PKI 所在目录权限为 0700。私钥不通过 SCP/SFTP/rsync 或 Caddy HTTP 传输。根 CA 私钥和 admin 私钥始终保留在安装节点。
