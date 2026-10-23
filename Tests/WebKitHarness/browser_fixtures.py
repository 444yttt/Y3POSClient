"""Fictional daily report used by the actual native BrowserModel harness.

The scenario query prevents these paths from replacing the older independent
script fixtures. No request is sent to the production service.
"""
import json
from urllib.parse import parse_qs

BASE = "/scripts/verona/print/prtz030"
QUERY = "?scenario=native-browser"


def page(body, script=""):
    return f'''<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空売上日報</title>
    <style>body{{margin:8px;font:12px serif}}table{{border-collapse:collapse}}td,th{{border:1px solid #aaa;padding:4px;white-space:nowrap}}</style>
    </head><body>{body}<script>{script}</script></body></html>'''


def replacement_response(path, method, values):
    """A source-owned document rewrite after the native discovery retries end."""
    query = "?scenario=native-replacement"
    if path == BASE + "_1.asp":
        return f'''<!doctype html><html><head><title>架空遅延帳票</title></head>
        <frameset rows="115,*" cols="*"><frame name="native-late-condition" src="{BASE}_1_1.asp{query}">
        <frame name="native-late-data" src="{BASE}_2_2.asp{query}"></frameset></html>'''
    if path == BASE + "_1_1.asp":
        return page(f'''<form id="native-replacement-search" method="post" action="{BASE}_2_2.asp{query}" target="native-late-data">
        <label>日付<input name="ft_YYYYMMDD_F" maxlength="8" value="20261018"></label>
        <input type="hidden" name="unchanged" value="FICTIONAL-REPLACEMENT-TOKEN">
        <input type="button" name="ken" value="表示" onclick="this.form.submit()"></form>''')
    if path == BASE + "_2_2.asp":
        if method != "POST":
            return page("")
        request = json.dumps({"method": method, "values": values or {}}, ensure_ascii=False)
        replacement = json.dumps('''<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空遅延帳票</title></head>
        <body><h1>架空遅延帳票</h1><div id="native-replacement-grid"></div></body></html>''', ensure_ascii=False).replace("</", "<\\/")
        table = json.dumps('''<table id="native-replacement-table" width="1100"><tr><th>商品</th><th>数量</th><th>金額</th></tr>
        <tr><td>架空商品A</td><td>2</td><td>200</td></tr><tr><td>架空商品B</td><td>3</td><td>300</td></tr></table>
        <input id="native-replacement-action" type="button" value="原処理" onclick="window.fixtureReplacementActionCount=(window.fixtureReplacementActionCount||0)+1">''', ensure_ascii=False)
        return page("", f'''window.fixtureReplacementRequest={request};
        window.addEventListener('load',()=>setTimeout(()=>{{
          document.open();document.write({replacement});document.close();
          window.fixtureReplacementRewritten=true;
          setTimeout(()=>{{
            document.getElementById('native-replacement-grid').innerHTML={table};
            window.fixtureReplacementTable=document.getElementById('native-replacement-table');
            window.fixtureReplacementAction=document.getElementById('native-replacement-action');
          }},200);
        }},6500),{{once:true}});''')
    return None


def response(path, query="", method="GET", values=None):
    options = parse_qs(query)
    if options.get("scenario") == ["native-replacement"]:
        return replacement_response(path, method, values)
    if options.get("scenario") != ["native-browser"]:
        return None
    if path == BASE + "_1.asp":
        return f'''<!doctype html><html><head><title>架空売上日報</title></head>
        <frameset id="prtz030_frameset" rows="115,*" cols="*"><frame name="prtz030_1_1" src="{BASE}_1_1.asp{QUERY}">
        <frame name="prtz030_2" src="{BASE}_2.asp{QUERY}&empty=1"></frameset></html>'''
    if path == BASE + "_1_1.asp":
        return page(f'''<form id="native-daily-search" name="form1" method="post" action="{BASE}_2.asp{QUERY}" target="prtz030_2">
        <input type="hidden" name="unchanged" value="FICTIONAL-NATIVE-SEARCH">
        <table><tr><td>日付</td><td><input name="ft_YYYYMMDD_F" maxlength="8" value="20261018">
        ～ <input name="ft_YYYYMMDD_T" maxlength="8" value="20261018"></td></tr></table>
        <input type="button" name="ken" value="表示" onclick="this.form.submit()"></form>
        <div id="ui-datepicker-div" style="display:none">架空カレンダー</div>''', '''
        window.fixtureNativeResizeTicks=0;
        window.addEventListener('load',()=>setInterval(()=>{
          window.fixtureNativeResizeTicks++;
          const calendar=document.getElementById('ui-datepicker-div');
          parent.document.getElementById('prtz030_frameset').rows=calendar.style.display==='block'?'350,*':'115,*';
        },200),{once:true});''')
    if path == BASE + "_2.asp":
        if options.get("empty") == ["1"]:
            return page("")
        request = json.dumps({"method": method, "values": values or {}}, ensure_ascii=False)
        return f'''<!doctype html><html><head><title>架空売上日報結果</title>
        <script>window.fixtureNativeRequest={request};</script></head>
        <frameset rows="60%,*" cols="*"><frame name="daily-main" src="{BASE}_2_2.asp{QUERY}">
        <frameset cols="*,40%" rows="*">
        <frame name="daily-tender" src="{BASE}_2_3.asp{QUERY}">
        <frame name="daily-category" src="{BASE}_2_4.asp{QUERY}"></frameset></frameset></html>'''
    if path in [BASE + "_2_2.asp", BASE + "_2_3.asp", BASE + "_2_4.asp"]:
        index = int(path[-5]) - 2
        if index == 0:
            header = "<tr><th rowspan='2'>区分</th><th colspan='13'>架空の売上日報</th></tr>"
            header += "<tr>" + "".join(f"<th>項目{i}</th>" for i in range(1, 14)) + "</tr>"
            body = "".join("<tr><td>架空集計</td>" + "".join(f"<td>{row * 10 + col}</td>" for col in range(13)) + "</tr>" for row in range(6))
            table = f'<table id="native-daily-table-0" data-fixture-daily="0" width="1400">{header}{body}</table>'
        elif index == 1:
            table = '<table id="native-daily-table-1" data-fixture-daily="1" width="700"><tr><th>金種</th><th>件数</th><th>金額</th><th>構成比</th><th>区分</th></tr>'
            table += "".join(f"<tr><td>架空金種{row}</td><td>{row}</td><td>{row * 100}</td><td>0</td><td>架空</td></tr>" for row in range(1, 7)) + "</table>"
        else:
            table = '<table id="native-daily-table-2" data-fixture-daily="2"><tr><td><table><tr><th>区分</th><th>合計</th></tr><tr><td>架空分類</td><td>42</td></tr></table></td><td><table><tr><th>指標</th><th>合計</th></tr><tr><td>架空指標</td><td>24</td></tr></table></td></tr></table>'
        content = json.dumps(table, ensure_ascii=False).replace("</", "<\\/")
        # The first result builds after the native controller already focused the
        # condition frame. Other siblings finish earlier, as on legacy reports.
        delay = 1600 if index == 0 else 30
        script = f'''window.addEventListener('load',()=>setTimeout(()=>{{
          document.getElementById('native-daily-grid').innerHTML={content};
          window.fixtureNativeDataReady=true;
        }},{delay}),{{once:true}});'''
        return page('<div id="native-daily-grid"></div>', script)
    return None
