# deploy_ss_opt.sh

## 用途

这个脚本用于在 Debian / Ubuntu 服务器上部署 `shadowsocks-libev`。

核心能力：

- 单实例部署：监听 `0.0.0.0:<PORT>`。
- 多实例部署：每个实例独立监听指定 IP / 端口。
- 多实例可指定独立出口 IP，让代理流量从指定公网 IP 对外显示。
- 自动写入 source-based policy route，提升多公网 IP / 多出口场景下的出口稳定性。
- 为每个实例生成可导入 Clash 的 YAML 文件。
- 可选启动 HTTP 静态服务，输出每个客户端自己的 YAML 地址。
- 输出 `ss://` 链接、Clash 节点片段、YAML 文件；启用 HTTP 时额外输出 HTTP 地址，并保存到 `/root/ss_uri.txt`。

## 环境要求

- Debian / Ubuntu，且使用 `systemd`
- root 权限
- 服务器上已绑定需要使用的公网 IP
- 云厂商安全组放行对应端口的 TCP / UDP

## 快速开始

单实例：

```bash
sudo bash deploy_ss_opt.sh
```

多实例，监听 IP 和出口 IP 相同：

```bash
sudo bash /root/deploy_ss_opt.sh \
  --method chacha20-ietf-poly1305 \
  --yaml-http-enable yes \
  --yaml-http-bind 0.0.0.0 \
  --yaml-http-host 72.249.207.28 \
    --instance '72.249.207.28|443|us-node01-01|password|72.249.207.28' \
    --instance '23.144.132.62|443|us-node01-02|password|23.144.132.62'
```

启用 YAML HTTP 后会生成类似下面的地址：

```text
http://72.249.207.28:18080/192.168.10.35.yaml
http://72.249.207.28:18080/192.168.10.45.yaml
```

每台客户端只需要拿自己的 YAML 文件或 HTTP 地址即可，复制后可直接导入 Clash 使用。

多实例，监听 IP 和出口 IP 分开控制：

```bash
sudo bash /root/deploy_ss_opt.sh \
    --instance '72.249.207.28|443|us-node01-01|password|72.249.207.28' \
    --instance '23.144.132.62|443|us-node01-02|password|23.144.132.62'
```

## 多实例格式

```text
LISTEN_IP|PORT|TAG|PASSWORD|EGRESS_IP
```

- `LISTEN_IP`：服务监听 IP，必须已绑定在本机。
- `PORT`：监听端口，可空，默认使用 `--port` 或 `443`。
- `TAG`：节点显示名称，可空。
- `PASSWORD`：节点密码，可空；已有实例会复用旧密码，新实例会自动生成。
- `EGRESS_IP`：出口 IP，可空；默认等于 `LISTEN_IP`，必须已绑定在本机。

## 出口控制逻辑

多实例模式下，每个实例会生成：

- `/etc/shadowsocks-libev/<实例名>.json`
- `/etc/shadowsocks-libev/<实例名>.egress`
- `/root/clash-yaml/<TAG>.yaml`
- `shadowsocks-libev-ss@<实例名>.service`

实例服务启动时会执行：

```bash
ss-server -c <实例配置> -b <EGRESS_IP>
```

同时脚本默认写入源地址策略路由：

```text
from <EGRESS_IP> lookup <独立路由表>
```

这样可以让不同实例的出站连接按源地址进入对应路由表，减少系统默认路由导致的出口漂移。

## 主要参数

- `--password <PASS>`：单实例密码。
- `--port <PORT>`：默认端口，默认 `443`。
- `--method <METHOD>`：加密方式，默认 `chacha20-ietf-poly1305`。
- `--tag <TAG>`：单实例节点名。
- `--server-ip <IP>`：单实例输出地址覆盖。
- `--enable-ufw <auto|yes|no>`：是否自动配置 UFW。
- `--enable-egress-route <auto|yes|no>`：多实例是否写入源地址策略路由，默认 `auto`。
- `--egress-probe-ip <IP>`：用于探测出口网关和网卡的目标 IP，默认 `1.1.1.1`。
- `--conf-name <NAME>`：多实例配置名前缀，默认 `ss443`。
- `--out-file <PATH>`：输出文件，默认 `/root/ss_uri.txt`。
- `--yaml-dir <PATH>`：Clash YAML 输出目录，默认 `/root/clash-yaml`。
- `--yaml-http-enable <yes|no>`：是否启动 YAML HTTP 服务，默认 `no`。
- `--yaml-http-port <PORT>`：YAML HTTP 服务端口，默认 `18080`。
- `--yaml-http-host <HOST>`：生成 HTTP 地址时使用的公网 IP 或域名，默认自动选择。
- `--yaml-http-bind <ADDR>`：YAML HTTP 服务监听地址，默认 `127.0.0.1`；需要公网访问时显式设置为 `0.0.0.0`。
- `--instance <SPEC>`：多实例配置，可重复传入。

## 注意事项

- `LISTEN_IP` 和 `EGRESS_IP` 都必须是本机已有地址。
- 如果服务器有多网卡 / 多网关，建议保持 `--enable-egress-route auto`。
- 如果路由探测失败，可以先检查 `ip route get 1.1.1.1 from <EGRESS_IP>`。
- 已存在的 YAML 文件只有在归属实例匹配时才会覆盖；如果 `TAG` 归一化后撞到其他实例文件，脚本会拒绝继续。
- 当脚本管理 UFW 时，端口放行或 reload 失败会中止部署；如果只使用云安全组，可以保持 `--enable-ufw auto` 或设为 `no`。
- YAML HTTP 服务默认不启动；需要公网 HTTP 地址时加 `--yaml-http-enable yes --yaml-http-bind 0.0.0.0`，并在安全组放行 `18080/tcp`。
- YAML 文件和 HTTP 地址包含明文节点密码，只发给对应客户端。
- 输出文件包含明文密码，请妥善保管。
- 本项目内容仅供合法授权的服务器运维、学习和测试使用。
