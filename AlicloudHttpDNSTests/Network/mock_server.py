#!/usr/bin/env python3
"""
HTTP/HTTPS Mock Server for HttpdnsNWHTTPClient Integration Tests

模拟 httpbin.org 的核心功能，用于替代不稳定的外部依赖。
支持 HTTP (端口 11080) 和多个 HTTPS 端口 (11443-11446，自签名证书)。

使用方法:
    python3 mock_server.py

端口配置:
    - HTTP:  127.0.0.1:11080
    - HTTPS: 127.0.0.1:11443, 11444, 11445, 11446

注意:
    - 使用非特权端口，无需 root 权限
    - HTTPS 使用自签名证书，测试时需禁用 TLS 验证
    - 多个 HTTPS 端口用于测试连接池隔离
    - 按 Ctrl+C 停止服务器
"""

import json
import time
import uuid
import ssl
import os
import subprocess
import signal
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from threading import Thread
from socketserver import ThreadingMixIn


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    """多线程 HTTP 服务器，支持并发请求"""
    daemon_threads = True
    allow_reuse_address = True


class MockHTTPHandler(BaseHTTPRequestHandler):
    """模拟 httpbin.org 的请求处理器"""

    # 使用 HTTP/1.1 协议（支持 keep-alive）
    protocol_version = 'HTTP/1.1'

    # 禁用日志输出（可选，便于查看测试输出）
    def log_message(self, format, *args):
        # 取消注释以启用详细日志
        # print(f"[{self.address_string()}] {format % args}")
        pass

    def do_GET(self):
        """处理 GET 请求"""
        path = urlparse(self.path).path

        if path == '/get':
            self._handle_get()
        elif path.startswith('/status/'):
            self._handle_status(path)
        elif path.startswith('/stream-bytes/'):
            self._handle_stream_bytes(path)
        elif path.startswith('/delay/'):
            self._handle_delay(path)
        elif path == '/headers':
            self._handle_headers()
        elif path == '/uuid':
            self._handle_uuid()
        elif path == '/user-agent':
            self._handle_user_agent()
        elif path == '/connection-test':
            self._handle_connection_test()
        else:
            self._handle_not_found()

    def _handle_get(self):
        """模拟 /get - 返回请求信息"""
        data = {
            'args': {},
            'headers': dict(self.headers),
            'origin': self.client_address[0],
            'url': f'{self.command} {self.path}'
        }
        self._send_json(200, data)

    def _handle_status(self, path):
        """模拟 /status/{code} - 返回指定状态码"""
        try:
            status_code = int(path.split('/')[-1])
            # 限制状态码范围在 100-599
            if 100 <= status_code < 600:
                self._send_json(status_code, {'status': status_code})
            else:
                self._send_json(400, {'error': 'Invalid status code'})
        except (ValueError, IndexError):
            self._send_json(400, {'error': 'Invalid status code format'})

    def _handle_stream_bytes(self, path):
        """模拟 /stream-bytes/{n} - 返回 chunked 编码的 n 字节数据"""
        try:
            n = int(path.split('/')[-1])
        except (ValueError, IndexError):
            self._send_json(400, {'error': 'Invalid byte count'})
            return

        # 发送 chunked 响应
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.send_header('Connection', 'keep-alive')
        self.end_headers()

        # 发送 chunk
        chunk_data = b'X' * n
        chunk_size_hex = f'{n:x}\r\n'.encode('utf-8')
        self.wfile.write(chunk_size_hex)
        self.wfile.write(chunk_data)
        self.wfile.write(b'\r\n')

        # 发送最后一个 chunk (size=0)
        self.wfile.write(b'0\r\n\r\n')
        self.wfile.flush()  # 确保数据发送

    def _handle_delay(self, path):
        """模拟 /delay/{seconds} - 延迟指定秒数后返回"""
        try:
            seconds = int(path.split('/')[-1])
        except (ValueError, IndexError):
            self._send_json(400, {'error': 'Invalid delay value'})
            return

        # 最多延迟 10 秒（防止意外）
        seconds = min(seconds, 10)
        time.sleep(seconds)

        data = {
            'args': {},
            'headers': dict(self.headers),
            'origin': self.client_address[0],
            'url': f'{self.command} {self.path}',
            'delayed': seconds
        }
        self._send_json(200, data)

    def _handle_headers(self):
        """模拟 /headers - 返回所有请求头部"""
        data = {
            'headers': dict(self.headers)
        }
        self._send_json(200, data)

    def _handle_uuid(self):
        """模拟 /uuid - 返回随机 UUID"""
        data = {
            'uuid': str(uuid.uuid4())
        }
        self._send_json(200, data)

    def _handle_user_agent(self):
        """模拟 /user-agent - 返回 User-Agent 头部"""
        data = {
            'user-agent': self.headers.get('User-Agent', '')
        }
        self._send_json(200, data)

    def _handle_connection_test(self):
        """处理 /connection-test - 返回指定的 Connection 头部用于测试"""
        from urllib.parse import parse_qs

        # 解析查询参数
        query_string = urlparse(self.path).query
        params = parse_qs(query_string)
        mode = params.get('mode', ['keep-alive'])[0]

        data = {
            'mode': mode,
            'message': f'Connection header test with mode: {mode}'
        }

        body = json.dumps(data).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', len(body))

        # 根据 mode 参数设置不同的 Connection 头部
        if mode == 'close':
            self.send_header('Connection', 'close')
        elif mode == 'proxy-close':
            self.send_header('Proxy-Connection', 'close')
            self.send_header('Connection', 'keep-alive')
        elif mode == 'close-uppercase':
            self.send_header('CONNECTION', 'CLOSE')
        elif mode == 'close-mixed':
            self.send_header('Connection', 'Close')
        else:  # keep-alive (default)
            self.send_header('Connection', 'keep-alive')

        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _handle_not_found(self):
        """处理未知路径"""
        self._send_json(404, {'error': 'Not Found', 'path': self.path})

    def _send_json(self, status_code, data):
        """发送 JSON 响应"""
        try:
            body = json.dumps(data).encode('utf-8')
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', len(body))
            # 支持 HTTP/1.1 keep-alive
            self.send_header('Connection', 'keep-alive')
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()  # 确保数据发送
        except Exception as e:
            print(f"Error sending response: {e}", file=sys.stderr)


def create_self_signed_cert(cert_file='server.pem'):
    """生成自签名证书（如果不存在）"""
    if os.path.exists(cert_file):
        print(f"✓ 使用现有证书: {cert_file}")
        return cert_file

    print(f"正在生成自签名证书: {cert_file} ...")
    try:
        subprocess.run([
            'openssl', 'req', '-x509', '-newkey', 'rsa:2048',
            '-keyout', cert_file, '-out', cert_file,
            '-days', '365', '-nodes',
            '-subj', '/CN=localhost'
        ], check=True, capture_output=True)
        print(f"✓ 证书生成成功")
        return cert_file
    except subprocess.CalledProcessError as e:
        print(f"✗ 证书生成失败: {e.stderr.decode()}", file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("✗ 未找到 openssl 命令，请安装 OpenSSL", file=sys.stderr)
        sys.exit(1)


def run_http_server(port=11080):
    """运行 HTTP 服务器"""
    try:
        server = ThreadedHTTPServer(('127.0.0.1', port), MockHTTPHandler)
        print(f"✓ HTTP 服务器运行在 http://127.0.0.1:{port}")
        server.serve_forever()
    except OSError as e:
        if e.errno == 48:  # Address already in use
            print(f"✗ 端口 {port} 已被占用，请关闭占用端口的进程或使用其他端口", file=sys.stderr)
        else:
            print(f"✗ HTTP 服务器启动失败: {e}", file=sys.stderr)
        sys.exit(1)


def run_https_server(port=11443, cert_file='server.pem'):
    """运行 HTTPS 服务器（使用自签名证书）"""
    try:
        server = ThreadedHTTPServer(('127.0.0.1', port), MockHTTPHandler)

        # 配置 SSL 上下文
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_file)

        # 包装 socket
        server.socket = context.wrap_socket(server.socket, server_side=True)

        print(f"✓ HTTPS 服务器运行在 https://127.0.0.1:{port} (自签名证书)")
        server.serve_forever()
    except OSError as e:
        if e.errno == 48:  # Address already in use
            print(f"✗ 端口 {port} 已被占用，请关闭占用端口的进程或使用其他端口", file=sys.stderr)
        else:
            print(f"✗ HTTPS 服务器启动失败: {e}", file=sys.stderr)
        sys.exit(1)
    except ssl.SSLError as e:
        print(f"✗ SSL 配置失败: {e}", file=sys.stderr)
        sys.exit(1)


def signal_handler(sig, frame):
    """处理 Ctrl+C 信号"""
    print("\n\n✓ 服务器已停止")
    sys.exit(0)


def main():
    """主函数"""
    # 注册信号处理器
    signal.signal(signal.SIGINT, signal_handler)

    # 生成自签名证书
    script_dir = os.path.dirname(os.path.abspath(__file__))
    cert_file = os.path.join(script_dir, 'server.pem')
    create_self_signed_cert(cert_file)

    print("\n" + "="*60)
    print("  HttpdnsNWHTTPClient Mock Server")
    print("="*60)
    print("\n支持的 endpoints:")
    print("  GET /get              - 返回请求信息")
    print("  GET /status/{code}    - 返回指定状态码")
    print("  GET /stream-bytes/N   - 返回 chunked 编码的 N 字节数据")
    print("  GET /delay/N          - 延迟 N 秒后返回")
    print("  GET /headers          - 返回所有请求头部")
    print("  GET /uuid             - 返回随机 UUID")
    print("  GET /user-agent       - 返回 User-Agent 头部")
    print("  GET /connection-test?mode={mode}")
    print("                        - 返回指定 Connection 头部")
    print("                          mode: close, keep-alive, proxy-close,")
    print("                                close-uppercase, close-mixed")
    print("\n按 Ctrl+C 停止服务器\n")
    print("="*60 + "\n")

    # 启动 HTTP 和 HTTPS 服务器（使用线程）
    http_thread = Thread(target=run_http_server, args=(11080,), daemon=True)

    # 启动多个 HTTPS 端口用于测试连接复用隔离
    https_ports = [11443, 11444, 11445, 11446]
    https_threads = []

    http_thread.start()
    time.sleep(0.5)  # 等待 HTTP 服务器启动

    # 启动所有 HTTPS 服务器
    for port in https_ports:
        https_thread = Thread(target=run_https_server, args=(port, cert_file), daemon=True)
        https_threads.append(https_thread)
        https_thread.start()
        time.sleep(0.1)  # 错峰启动避免端口冲突

    # 主线程等待（保持服务器运行）
    try:
        http_thread.join()
        for thread in https_threads:
            thread.join()
    except KeyboardInterrupt:
        signal_handler(signal.SIGINT, None)


if __name__ == '__main__':
    main()
