#!/usr/bin/env python3
"""Copy OpenCTI's documents from Elasticsearch to OpenSearch, index by index.

The target indices must already exist with OpenCTI's own structure (init-schema.sh).
Documents keep their _id; the source is only read (scroll). Each target index is
refreshed off during the copy and restored afterwards, then counts are compared.
Stop everything that writes to the source first, or the counts will differ.

Usage (from the OpenCTI host, which reaches both):
    copy-indices.py --source http://<elasticsearch>:9200 \
                    --target https://<opensearch host>:9200 --ca opensearch-ca.pem \
                    --user opencti --password-file opencti-user.env [--workers 6]

--password-file holds OPENCTI_PASSWORD=... (the password is never printed).
--source-auth also logs in to the source, for a copy between two OpenSearch nodes
(e.g. to a lower version, where a snapshot cannot be restored).
Standard library only.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import queue
import ssl
import sys
import threading
import time
import urllib.parse

BATCH_DOCS = 2000
BATCH_BYTES = 8 * 1024 * 1024
SCROLL = "10m"


class Endpoint:
    """One keep-alive HTTP(S) connection per thread to a cluster."""

    def __init__(self, url: str, auth: str | None = None, ca: str | None = None):
        self.url = urllib.parse.urlsplit(url)
        self.headers = {"Content-Type": "application/json"}
        if auth:
            self.headers["Authorization"] = "Basic " + base64.b64encode(auth.encode()).decode()
        self.ctx = ssl.create_default_context(cafile=ca) if self.url.scheme == "https" else None
        if self.ctx:  # Python 3.13+ is strict by default; make-certs.sh's CA has no keyUsage
            self.ctx.verify_flags &= ~ssl.VERIFY_X509_STRICT
        self.local = threading.local()

    def _conn(self) -> http.client.HTTPConnection:
        conn = getattr(self.local, "conn", None)
        if conn is None:
            if self.ctx:
                conn = http.client.HTTPSConnection(self.url.hostname, self.url.port or 443,
                                                   context=self.ctx, timeout=300)
            else:
                conn = http.client.HTTPConnection(self.url.hostname, self.url.port or 80, timeout=300)
            self.local.conn = conn
        return conn

    def request(self, method: str, path: str, body: bytes | str | None = None,
                ndjson: bool = False) -> tuple[int, dict]:
        headers = dict(self.headers)
        if ndjson:
            headers["Content-Type"] = "application/x-ndjson"
        data = body.encode() if isinstance(body, str) else body
        for attempt in range(6):
            try:
                conn = self._conn()
                conn.request(method, path, body=data, headers=headers)
                resp = conn.getresponse()
                raw = resp.read()
                if resp.status in (429, 502, 503, 504):
                    raise ConnectionError(f"HTTP {resp.status}")
                return resp.status, (json.loads(raw) if raw else {})
            except (ConnectionError, OSError, http.client.HTTPException) as err:
                self.local.conn = None
                if attempt == 5:
                    raise
                time.sleep(2 ** attempt)
                print(f"  retry {method} {path.split('?')[0]}: {err}", file=sys.stderr)
        raise RuntimeError("unreachable")


def copy_index(src: Endpoint, dst: Endpoint, index: str, workers: int) -> int:
    status, _ = dst.request("GET", f"/{index}/_count")
    if status != 200:
        raise SystemExit(f"target index {index} missing (run init-schema.sh): HTTP {status}")
    # An unset setting comes back as {} (not even the index name): treat it as the default.
    _, settings = dst.request("GET", f"/{index}/_settings/index.refresh_interval?flat_settings=true")
    refresh = settings.get(index, {}).get("settings", {}).get("index.refresh_interval")
    dst.request("PUT", f"/{index}/_settings", json.dumps({"index": {"refresh_interval": "-1"}}))

    batches: queue.Queue = queue.Queue(maxsize=workers * 2)
    errors: list[str] = []
    copied = [0]
    lock = threading.Lock()

    def sender() -> None:
        while (batch := batches.get()) is not None:
            body, count = batch
            status, result = dst.request("POST", "/_bulk?filter_path=errors,items.*.error", body, ndjson=True)
            if status != 200 or result.get("errors"):
                with lock:
                    errors.append(json.dumps(result)[:500] if result else f"HTTP {status}")
            with lock:
                copied[0] += count
            batches.task_done()
        batches.task_done()

    threads = [threading.Thread(target=sender, daemon=True) for _ in range(workers)]
    for t in threads:
        t.start()

    status, page = src.request("POST", f"/{index}/_search?scroll={SCROLL}",
                               json.dumps({"size": BATCH_DOCS, "sort": ["_doc"]}))
    scroll_id = page.get("_scroll_id")
    started, lines, count, size = time.time(), [], 0, 0
    while page.get("hits", {}).get("hits"):
        for hit in page["hits"]["hits"]:
            meta = {"_index": index, "_id": hit["_id"]}
            if hit.get("_routing"):
                meta["routing"] = hit["_routing"]
            source = json.dumps(hit["_source"], separators=(",", ":"))
            lines.append('{"index":' + json.dumps(meta) + "}\n" + source + "\n")
            count += 1
            size += len(source)
            if count >= BATCH_DOCS or size >= BATCH_BYTES:
                batches.put(("".join(lines), count))
                lines, count, size = [], 0, 0
        status, page = src.request("POST", "/_search/scroll", json.dumps({"scroll": SCROLL, "scroll_id": scroll_id}))
        scroll_id = page.get("_scroll_id", scroll_id)
        if errors:
            break
    if lines:
        batches.put(("".join(lines), count))
    for _ in threads:
        batches.put(None)
    batches.join()
    src.request("DELETE", "/_search/scroll", json.dumps({"scroll_id": scroll_id}))

    restore = {"index": {"refresh_interval": refresh}} if refresh else {"index": {"refresh_interval": None}}
    dst.request("PUT", f"/{index}/_settings", json.dumps(restore))
    dst.request("POST", f"/{index}/_refresh")
    if errors:
        raise SystemExit(f"{index}: bulk errors, first one: {errors[0]}")
    elapsed = time.time() - started
    print(f"  {index}: {copied[0]} docs in {elapsed:.0f}s ({copied[0] / max(elapsed, 1):.0f}/s)", flush=True)
    return copied[0]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", required=True)
    ap.add_argument("--target", required=True)
    ap.add_argument("--ca", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password-file", required=True)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--prefix", default="opencti")
    ap.add_argument("--source-auth", action="store_true",
                    help="log in to the source too (same user, password and CA): OpenSearch to OpenSearch")
    ap.add_argument("--source-ca", help="with --source-auth: the source's own CA (default: --ca)")
    ap.add_argument("--source-password-file",
                    help="with --source-auth: the source's own OPENCTI_PASSWORD=... (default: --password-file)")
    args = ap.parse_args()

    def read_password(path: str) -> str:
        return next(line.split("=", 1)[1].strip() for line in open(path)
                    if line.startswith("OPENCTI_PASSWORD="))

    password = read_password(args.password_file)
    src_password = read_password(args.source_password_file) if args.source_password_file else password
    src = (Endpoint(args.source, auth=f"{args.user}:{src_password}", ca=args.source_ca or args.ca)
           if args.source_auth else Endpoint(args.source))
    dst = Endpoint(args.target, auth=f"{args.user}:{password}", ca=args.ca)
    _, indices = src.request("GET", f"/_cat/indices/{args.prefix}_*?format=json&h=index,docs.count&s=index")
    total_started = time.time()
    print(f"copying {len(indices)} indices with {args.workers} parallel bulk senders", flush=True)
    for item in sorted(indices, key=lambda i: int(i["docs.count"])):
        copy_index(src, dst, item["index"], args.workers)

    print("verifying counts (source at copy time vs target):")
    mismatched = 0
    for item in indices:
        _, s = src.request("GET", f"/{item['index']}/_count")
        _, d = dst.request("GET", f"/{item['index']}/_count")
        mark = "ok" if s["count"] == d["count"] else "DIFF (source still written to?)"
        mismatched += s["count"] != d["count"]
        print(f"  {item['index']:<45} source={s['count']:>9} target={d['count']:>9} {mark}")
    print(f"done in {time.time() - total_started:.0f}s, {mismatched} index(es) differ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
