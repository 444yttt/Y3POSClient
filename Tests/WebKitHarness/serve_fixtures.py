#!/usr/bin/env python3
"""Loopback-only fictional inventory fixtures; never proxy external requests."""

import argparse
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
from receipt_fixtures import response as receipt_response


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


def select_radio_search(result_pager=False):
    """Legacy search controls deliberately have no text inputs or prebuilt labels."""
    action = BASE + "prtz030_2.asp" + ("?scenario=result-pager" if result_pager else "")
    return page('''<form id="select-radio-search" name="frmSearch" method="post"
    action="''' + action + '''" target="prtz030_2"
    onsubmit="window.fixtureSearchSubmissions++;window.fixtureLastSubmission=Object.fromEntries(new FormData(this));return true">
    <input id="search-token" type="hidden" name="unchanged" value="FICTIONAL-SEARCH-TOKEN">
    <table id="select-radio-table" width="700"><tbody>
    <tr><td id="search-store-label">店舗</td><td><select id="search-store" name="shop_code"
    onchange="window.fixtureSelectChanges++"><option value="all">全店舗</option><option value="west">架空西店舗</option></select></td></tr>
    <tr><td id="search-group-label">集計単位</td><td><input id="group-store" type="radio" name="group_by" value="store" checked
    onclick="window.fixtureRadioClicks++">店舗別<br><input id="group-product" type="radio" name="group_by" value="product"
    onclick="window.fixtureRadioClicks++">商品別</td></tr>
    <tr><td></td><td><input id="search-submit" type="submit" name="search" value="検索"></td></tr>
    </tbody></table></form>''', '''<script>
    window.fixtureSelectChanges=0;window.fixtureRadioClicks=0;window.fixtureSearchSubmissions=0;
    window.fixtureLastSubmission=null;
    window.fixtureSearchOriginals={form:document.getElementById('select-radio-search'),
      select:document.getElementById('search-store'),store:document.getElementById('group-store'),
      product:document.getElementById('group-product'),submit:document.getElementById('search-submit'),
      hidden:document.getElementById('search-token')};
    window.fixtureSearchHandlers={submit:fixtureSearchOriginals.form.onsubmit,
      select:fixtureSearchOriginals.select.onchange,radio:fixtureSearchOriginals.product.onclick};
    </script>''')


def select_radio_result(method="GET", values=None, result_pager=False):
    submitted = {key: value[-1] if isinstance(value, list) else value for key, value in (values or {}).items()}
    state = json.dumps({"method": method, "values": submitted}, ensure_ascii=False).replace("</", "<\\/")
    selected = submitted.get("PgSelect", "1")
    if selected not in ["1", "2"]:
        selected = "1"
    pager = ""
    if result_pager:
        options = "".join(f'<option value="{value}"' + (' selected' if value == selected else '') + f'>{value}</option>' for value in ["1", "2"])
        pager = f'''<form id="result-pager" method="post"
        action="{BASE}prtz030_2.asp?scenario=result-pager" target="prtz030_2"
        onsubmit="window.fixturePagerSubmissions++;return true">
        <input type="hidden" name="unchanged" value="FICTIONAL-PAGER-TOKEN">
        <select id="result-page" name="PgSelect" aria-label="結果のページ">{options}</select>
        <input id="result-page-submit" type="submit" value="表示"></form>'''
    return page('''<table id="select-radio-result"><tr><th>店舗名</th><th>売上</th></tr>
    <tr><td>架空店舗</td><td>123</td></tr></table>''' + pager, f'''<script>
    const fixtureRequest={state};window.fixtureRequestMethod=fixtureRequest.method;
    window.fixtureSubmittedQuery=fixtureRequest.values;
    {"window.fixturePagerSubmissions=0;window.fixtureSelectedPgSelect=" + json.dumps(selected) + ";" if result_pager else ""}
    </script>''')


def frozen_width_report():
    """Paired original grids have unequal scroll ranges and must stay in table mode."""
    return page('''<div id="D_FIXTURE_H" style="position:absolute;left:0;top:0;width:100%;max-width:100%;height:44px;overflow-x:auto;overflow-y:hidden">
    <table id="FIXTURE_H" width="1200" style="width:1200px!important;min-width:1200px;table-layout:fixed"><tbody>
    <tr><th colspan="2">商品・店舗</th><th>数量</th><th>売上</th><th>区分</th></tr></tbody></table></div>
    <div id="D_FIXTURE_B" style="position:absolute;left:0;top:44px;width:100%;max-width:100%;height:180px;overflow-x:auto;overflow-y:hidden">
    <table id="FIXTURE_B" width="1800" style="width:1800px!important;min-width:1800px;table-layout:fixed"><tbody>
    <tr><td><a id="frozen-product" href="javascript:void(0)" onclick="window.fixtureFrozenLinkClicks++;return false">架空商品A</a></td><td>架空店舗A</td><td>3</td><td>123</td><td>通常</td></tr>
    <tr><td>架空商品B</td><td>架空店舗B</td><td>5</td><td>456</td><td>通常</td></tr>
    <tr><td>架空商品C</td><td>架空店舗C</td><td>7</td><td>789</td><td>通常</td></tr>
    </tbody></table></div>''', '''<script>
    window.fixtureFrozenLinkClicks=0;
    window.fixtureFrozenOriginals={header:document.getElementById('FIXTURE_H'),
      body:document.getElementById('FIXTURE_B'),link:document.getElementById('frozen-product')};
    window.fixtureFrozenLinkHandler=fixtureFrozenOriginals.link.onclick;
    window.fixtureFrozenMetrics=()=>Object.fromEntries(['H','B'].map(suffix=>{
      const node=document.getElementById('D_FIXTURE_'+suffix);
      return [suffix,{left:node.scrollLeft,client:node.clientWidth,width:node.scrollWidth,
        max:node.scrollWidth-node.clientWidth}];
    }));
    </script>''')


def compound_form():
    """Keep the malformed fixture markup; only route its original POST locally."""
    source = (Path(__file__).resolve().parent.parent / "fixtures" / "compound-form.html").read_text(encoding="utf-8")
    source = source.replace('action="/fixture/compound-post"', f'action="{BASE}prtz098_2.asp"')
    baseline = '''<script>
    (()=>{
      const form=document.getElementById('fixture-compound-form');
      const controls=Array.from(form.elements);
      const calendar=document.getElementById('ui-datepicker-div');
      window.fixtureCompound={form,controls,
        ancestors:controls.map(control=>{const nodes=[];for(let ancestor=control.parentElement;ancestor;ancestor=ancestor.parentElement)nodes.push(ancestor);return nodes;}),
        fields:controls.map(field=>({field,form:field.form,name:field.name,type:field.type,value:field.value,
          onclick:field.onclick,onchange:field.onchange})),
        method:form.method,target:form.target,action:form.action,
        calendar,calendarHTML:calendar.outerHTML,nonAncestral:!form.contains(document.getElementById('fixture-date-start'))};
    })();
    </script>
    '''
    return source.replace("</body>", baseline + "</body>", 1)


def compound_result(method="GET", values=None):
    arrays = {key: value if isinstance(value, list) else [value] for key, value in (values or {}).items()}
    submitted = {key: value[0] if len(value) == 1 else value for key, value in arrays.items()}
    scalar = {key: value[-1] for key, value in arrays.items()}
    state = json.dumps({"method": method, "values": submitted, "arrays": arrays, "scalar": scalar}, ensure_ascii=False).replace("</", "<\\/")
    return page('<p id="fixture-compound-result">架空複合条件POST受信</p>', f'''<script>
    const fixtureCompoundRequest={state};
    window.fixtureRequestMethod=fixtureCompoundRequest.method;
    window.fixtureSubmittedValues=fixtureCompoundRequest.values;
    window.fixtureSubmittedArrays=fixtureCompoundRequest.arrays;
    window.fixtureSubmittedQuery=fixtureCompoundRequest.scalar;
    </script>''')


def maintenance_action_report(scenario=""):
    filenames = {
        "nested": "maintenance-nested-action-report.html",
        "frozen-clone": "maintenance-frozen-action-clone.html",
        "frozen-header": "maintenance-frozen-action-header.html",
        "checkbox-picker": "maintenance-selection-picker.html",
    }
    filename = filenames.get(scenario, "maintenance-action-report.html")
    source = (Path(__file__).resolve().parent.parent / "fixtures" / filename).read_text(encoding="utf-8")
    baseline = '''<script>
    (()=>{
      const controls=Array.from(document.querySelectorAll('input,select,textarea,button'));
      window.fixtureClicks=0;
      window.fixtureAction={tables:Array.from(document.querySelectorAll('table')),forms:Array.from(document.forms),controls,
        ancestors:controls.map(control=>{const nodes=[];for(let ancestor=control.parentElement;ancestor;ancestor=ancestor.parentElement)nodes.push(ancestor);return nodes;}),
        fields:controls.map(field=>({field,form:field.form,name:field.name,type:field.type,value:field.value,
          onclick:field.onclick,onchange:field.onchange}))};
    })();
    </script>'''
    return source.replace("</body>", baseline + "</body>", 1)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        parsed = urlsplit(self.path)
        report = re.fullmatch(r"/scripts/verona/(print|display|dwh)/(prtz(?:010|011|015))_([0-9_]+)\.asp", parsed.path)
        scenario = parse_qs(parsed.query).get("scenario", [""])[0]
        receipt = receipt_response(parsed.path, parsed.query, self.command, getattr(self, "fixture_post_values", None))
        if receipt is not None:
            body = receipt
        elif parsed.path == "/health":
            body = "ready"
        elif parsed.path in [BASE + "prtz011_3.asp", BASE + "prtz015_2_2.asp"] and scenario == "standalone":
            body = (Path(__file__).resolve().parent.parent / "fixtures" / "inventory-standalone-detail.html").read_text(encoding="utf-8")
        elif parsed.path == BASE + "prtz098_1_1.asp":
            body = compound_form()
        elif parsed.path == BASE + "prtz098_2.asp":
            body = compound_result(self.command, getattr(self, "fixture_post_values", None))
        elif parsed.path == BASE + "prtz098_4.asp":
            body = maintenance_action_report(scenario)
        elif parsed.path == BASE + "prtz098_7.asp" and scenario == "checkbox-picker":
            body = '''<!doctype html><html><head><title>架空分類選択フレーム</title></head>
            <frameset rows="*"><frame name="prtz098_8" src="/scripts/verona/print/prtz098_8.asp"></frameset></html>'''
        elif parsed.path == BASE + "prtz098_8.asp":
            body = maintenance_action_report("checkbox-picker")
        elif parsed.path in ["/fixture/post", "/fixture/selection-post"]:
            body = compound_result(self.command, getattr(self, "fixture_post_values", None))
        elif parsed.path == BASE + "prtz030_1.asp":
            query = "?scenario=result-pager" if scenario == "result-pager" else ""
            body = f'''<!doctype html><html><head><title>架空選択式検索</title></head>
            <frameset rows="240,*"><frame name="prtz030_1_1" src="/scripts/verona/print/prtz030_1_1.asp{query}">
            <frame name="prtz030_2" src="/scripts/verona/print/prtz030_2.asp{query}"></frameset></html>'''
        elif parsed.path == BASE + "prtz030_1_1.asp":
            body = select_radio_search(scenario == "result-pager")
        elif parsed.path == BASE + "prtz030_2.asp":
            body = select_radio_result(self.command, getattr(self, "fixture_post_values", None), scenario == "result-pager")
        elif parsed.path == BASE + "prtz030_2_2.asp" and scenario == "frozen-widths":
            body = frozen_width_report()
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
        payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.fixture_post_values = parse_qs(payload.decode("utf-8"), keep_blank_values=True)
        self.do_GET()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=17865)
    args = parser.parse_args()
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
