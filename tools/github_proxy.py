#!/usr/bin/env python3
"""github_proxy.py —— 本机当 CONNECT 代理, 给**局域网/内网里连不上 GitHub 的那台机器**借道。

    python3 tools/github_proxy.py [绑定地址] [端口]        # 默认 100.84.90.8 8899 (Tailscale 地址)

用途: 远端综合机 (PC/WSL2) 上 `docker build` 官方 Dockerfile 时, GitHub 连不通
(实测: DNS 正常、TCP 443 超时; 镜像站 ghfast.top 可用但拿不到 git 子模块的确定内容):

    docker build --build-arg BUILD_JOBS=4 \
      --build-arg HTTPS_PROXY=http://100.84.90.8:8899 --build-arg https_proxy=http://100.84.90.8:8899 \
      -t cpu2026:local .

要点:
- 只实现 CONNECT (git / curl 的 https 都走它), 只放行 443/80, 绑定 Tailscale 地址 ⇒ 校园网内不可见;
- 代理变量是 docker 的**预定义 build-arg**, 不用改 Dockerfile, 也**不会**烤进镜像 config (实测 .Config.Env 干净);
- 用完就关 (它没鉴权, 只该在 tailnet 内、构建期间开着)。
"""
import select
import socket
import socketserver
import sys

ALLOW_PORTS = {443, 80}
BUF = 65536


def pump(a, b):
    """双向搬运, 任一侧关闭即结束 (超时 120 s 防空占)。"""
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 120)
            if not r:
                return
            for s in r:
                data = s.recv(BUF)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        pass


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        cli = self.request
        cli.settimeout(30)
        try:
            buf = b""
            while b"\r\n\r\n" not in buf and len(buf) < 8192:
                chunk = cli.recv(1024)
                if not chunk:
                    return
                buf += chunk
            parts = buf.split(b"\r\n", 1)[0].decode("latin1").split()
            if len(parts) < 2 or parts[0] != "CONNECT":
                cli.sendall(b"HTTP/1.1 405 Only CONNECT\r\n\r\n")
                return
            host, _, port = parts[1].rpartition(":")
            port = int(port)
            if port not in ALLOW_PORTS:
                cli.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
                return
            up = socket.create_connection((host, port), timeout=30)
            cli.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            sys.stderr.write("[proxy] CONNECT %s:%d\n" % (host, port))
            sys.stderr.flush()
            up.settimeout(None)
            cli.settimeout(None)
            pump(cli, up)
            up.close()
        except Exception as e:  # 一条连接失败不算事
            sys.stderr.write("[proxy] err %s\n" % e)
            sys.stderr.flush()
        finally:
            try:
                cli.close()
            except OSError:
                pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    addr = sys.argv[1] if len(sys.argv) > 1 else "100.84.90.8"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8899
    with Server((addr, port), Handler) as srv:
        sys.stderr.write("[proxy] listening on %s:%d\n" % (addr, port))
        sys.stderr.flush()
        srv.serve_forever()
