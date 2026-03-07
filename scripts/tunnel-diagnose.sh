#!/usr/bin/env bash
# Run this on your LOCAL Mac (where you run the browser and ssh -L).
# Paste the full output back so we can see what's going on.

set -e
echo "=== 1. What is listening on 18790 and 18789 (local Mac)? ==="
(lsof -i :18790 2>/dev/null || echo "lsof: nothing on 18790")
(lsof -i :18789 2>/dev/null || echo "lsof: nothing on 18789")
echo ""

echo "=== 2. Curl root via 127.0.0.1:18790 (tunnel) ==="
curl -s -w "\nHTTP_CODE:%{http_code}\nCONNECT_TIME:%{time_connect}s\n" -o /tmp/curl_root.txt --max-time 5 http://127.0.0.1:18790/ || true
echo "Response length: $(wc -c < /tmp/curl_root.txt 2>/dev/null || echo 0) bytes"
echo "First 200 chars of response:"
head -c 200 /tmp/curl_root.txt 2>/dev/null | cat -v
echo ""
echo ""

echo "=== 3. Curl canvas path via 127.0.0.1:18790 ==="
curl -s -w "\nHTTP_CODE:%{http_code}\n" -o /tmp/curl_canvas.txt --max-time 5 http://127.0.0.1:18790/__openclaw__/canvas/ || true
echo "Response length: $(wc -c < /tmp/curl_canvas.txt 2>/dev/null || echo 0) bytes"
echo "First 500 chars:"
head -c 500 /tmp/curl_canvas.txt 2>/dev/null | cat -v
echo ""
echo ""

echo "=== 4. Curl -I (headers only) for canvas ==="
curl -s -I --max-time 5 http://127.0.0.1:18790/__openclaw__/canvas/ 2>&1 || true
echo ""

echo "=== 5. Done. Paste everything above. ==="
