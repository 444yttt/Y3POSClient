#!/usr/bin/env python3
"""Loopback-only fictional inventory fixtures; never proxy external requests."""

import argparse
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


BASE = "/scripts/verona/print/"
PRODUCT = "MOCK-WK001"


def page(body, script=""):
    return f'''<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空在庫照会</title>
    <style>body{{margin:8px;font:12px serif}}td,th{{border:1px solid #aaa;padding:4px;white-space:nowrap}}</style>
    </head><body>{body}{script}</body></html>'''


def metadata(base=BASE, family="prtz011", suffix="2_3"):
    return page(f'''<table id="inventory-summary" width="800"><tr><th>品番</th><th>作成日付</th></tr>
    <tr><td>{PRODUCT}</td><td>2026/10/17 12:00:00 現在</td></tr></table>
    <form name="form1" method="post" action="{base}{family}_{suffix}.asp" target="inventory-metadata">
    <input type="hidden" name="m01_hinban" value="{PRODUCT}"><input type="hidden" name="unchanged" value="FICTIONAL">
    <select name="PgSelect"><option value="1">1</option><option value="2">2</option></select>
    <input type="submit" name="hyouzi" value="表示"></form>''')


def matrix(unsupported=False, delayed=False):
    if unsupported:
        content = "<table><tr><th>日付</th><th>別の列</th></tr><tr><td>架空の日</td><td>架空の値</td></tr></table>"
    else:
        rows = []
        for size_index, code in enumerate(["313", "314", "315", "316", "317", "318", "総計"]):
            for metric_index, metric in enumerate(["有効在庫", "積送在庫", "取置在庫", "販売実績"]):
                first = f'<td rowspan="4">{code}</td>' if metric_index == 0 else ""
                quantity = str(size_index) if metric_index == 0 else ["", "0", "-", "-1"][metric_index]
                rows.append(f"<tr>{first}<td>{metric}</td><td>{size_index}{metric_index}</td><td>{quantity}</td><td></td></tr>")
        content = f'''<div id="D_T01_H"><table id="T01_H" width="625" style="width:625px;position:absolute;left:0;top:0"><tbody>
        <tr><th>品番</th><td>{PRODUCT}</td><th>商品名</th><td colspan="2"><a id="fixture-product" href="javascript:void(0)" onclick="window.fixtureLinkClicks=(window.fixtureLinkClicks||0)+1;return false">架空のシューズ</a></td></tr>
        <tr><th rowspan="2">サイズ</th><th rowspan="2"></th><th rowspan="2">合計</th><th colspan="2">カラー</th></tr>
        <tr><th>-4-</th><th></th></tr>{''.join(rows)}</tbody></table></div>'''
    # Like Tscroller, the original page constructs the matrix at load, AFTER document-end injection.
    encoded = json.dumps(content, ensure_ascii=False).replace("</", "<\\/")
    build = f"document.getElementById('fixture-grid').innerHTML={encoded};window.fixtureGridBuilt=true;"
    if delayed:
        build = "setTimeout(()=>{" + build + "},180);"
    script = f'''<script>window.fixtureLinkClicks=0;
    window.addEventListener('load',()=>{{{build}}});
    </script>'''
    return page('<div id="fixture-grid"></div>', script)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        report = re.fullmatch(r"/scripts/verona/(print|display|dwh)/(prtz(?:010|011|015))_([0-9_]+)\.asp", parsed.path)
        scenario = parse_qs(parsed.query).get("scenario", [""])[0]
        if parsed.path == "/health":
            body = "ready"
        elif report:
            branch, family, suffix = report.groups()
            base = f"/scripts/verona/{branch}/"
            if suffix == "2":
                if scenario == "structural":
                    # Reverse the roles, use arbitrary suffixes, insert an unrelated navigation frame,
                    # and build the grid after load. Native discovery must reconcile structural roles.
                    body = f'''<!doctype html><html><head><title>架空フレーム在庫</title></head>
                    <frameset rows="*,80,110"><frame name="inventory-matrix" src="{base}{family}_2_7.asp?scenario=late">
                    <frame name="inventory-navigation" src="{base}{family}_2_1.asp">
                    <frame name="inventory-metadata" src="{base}{family}_2_5.asp"></frameset></html>'''
                else:
                    query = "?scenario=unsupported" if scenario == "unsupported" else ""
                    body = f'''<!doctype html><html><head><title>架空フレーム在庫</title></head>
                    <frameset rows="110,*"><frame name="inventory-metadata" src="{base}{family}_2_3.asp">
                    <frame name="inventory-matrix" src="{base}{family}_2_2.asp{query}"></frameset></html>'''
            elif suffix in ["2_3", "2_5"]:
                body = metadata(base, family, suffix)
            elif suffix in ["2_2", "2_7"]:
                body = matrix(scenario == "unsupported", scenario == "late")
            elif suffix == "2_1":
                body = page(f'<a href="{base}{family}_1.asp" target="_top">検索条件</a>')
            else:
                self.send_error(404)
                return
        elif parsed.path == "/verona/data/cmtz030.asp":
            body = page('''<form name="login" method="post" action="/verona/data/cmtz030.asp" onsubmit="window.fixtureLoginPosts++;return false">
            <label>ID<input name="tanto_id" type="text"></label><label>Password<input name="tanto_pw" type="password"></label>
            <input type="submit" value="ログイン"></form><script>window.fixtureLoginPosts=0;</script>''')
        else:
            self.send_error(404)
            return
        payload = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.do_GET()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=17865)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
