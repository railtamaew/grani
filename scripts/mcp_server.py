#!/usr/bin/env python3
"""
Simple MCP (Model Context Protocol) HTTP Server
Runs on http://127.0.0.1:3845/mcp
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import sys

class MCPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            if self.path == '/mcp' or self.path == '/mcp/':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                response = {
                    "jsonrpc": "2.0",
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {
                            "tools": {},
                            "resources": {}
                        },
                        "serverInfo": {
                            "name": "grani-mcp-server",
                            "version": "1.0.0"
                        }
                    }
                }
                response_data = json.dumps(response).encode()
                self.wfile.write(response_data)
                self.wfile.flush()
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b'Not Found')
                self.wfile.flush()
        except Exception as e:
            print(f"Error in GET: {e}", file=sys.stderr)
            try:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
                self.wfile.flush()
            except:
                pass

    def do_POST(self):
        try:
            if self.path == '/mcp' or self.path == '/mcp/':
                content_length = int(self.headers.get('Content-Length', 0))
                body = self.rfile.read(content_length)
                
                try:
                    request = json.loads(body.decode())
                    method = request.get('method', '')
                    request_id = request.get('id')
                    
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/json')
                    self.send_header('Access-Control-Allow-Origin', '*')
                    self.end_headers()
                    
                    # Handle different MCP methods
                    if method == 'initialize':
                        response = {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "protocolVersion": "2024-11-05",
                                "capabilities": {
                                    "tools": {},
                                    "resources": {}
                                },
                                "serverInfo": {
                                    "name": "grani-mcp-server",
                                    "version": "1.0.0"
                                }
                            }
                        }
                    elif method == 'tools/list':
                        response = {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "tools": []
                            }
                        }
                    elif method == 'resources/list':
                        response = {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {
                                "resources": []
                            }
                        }
                    else:
                        response = {
                            "jsonrpc": "2.0",
                            "id": request_id,
                            "result": {}
                        }
                    
                    response_data = json.dumps(response).encode()
                    self.wfile.write(response_data)
                    self.wfile.flush()
                except Exception as e:
                    print(f"Error parsing request: {e}", file=sys.stderr)
                    self.send_response(400)
                    self.end_headers()
                    error_response = {
                        "jsonrpc": "2.0",
                        "id": request.get('id') if 'request' in locals() else None,
                        "error": {
                            "code": -32700,
                            "message": str(e)
                        }
                    }
                    self.wfile.write(json.dumps(error_response).encode())
                    self.wfile.flush()
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b'Not Found')
                self.wfile.flush()
        except Exception as e:
            print(f"Error in POST: {e}", file=sys.stderr)
            try:
                self.send_response(500)
                self.end_headers()
                self.wfile.write(json.dumps({"error": str(e)}).encode())
                self.wfile.flush()
            except:
                pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def log_message(self, format, *args):
        # Suppress default logging
        pass

def run(port=3845):
    server_address = ('127.0.0.1', port)
    httpd = HTTPServer(server_address, MCPHandler)
    print(f'MCP Server running on http://127.0.0.1:{port}/mcp')
    print('Press Ctrl+C to stop')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down MCP server...')
        httpd.shutdown()

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3845
    run(port)

