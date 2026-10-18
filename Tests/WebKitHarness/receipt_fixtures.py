"""Fictional receipt reports shared by Chromium and iOS WebKit regression tests."""
import json
from urllib.parse import parse_qs, urlencode

BASE = '/scripts/verona/print/prtz096'


def shell(body, script=''):
    return f'''<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空レシート照会</title>
    <style>body{{font:12px serif;margin:8px}}table{{border-collapse:collapse}}td,th{{border:1px solid #aaa;padding:4px;white-space:nowrap}}</style>
    </head><body>{body}<script>{script}</script></body></html>'''


def response(path, query='', method='GET', values=None):
    args = parse_qs(query)
    selected = (values or {}).get('PgSelect', args.get('page', ['1']))[-1]
    page = selected if selected in ['1', '2'] else '1'
    late = args.get('late', [''])[0]
    mode = args.get('mode', [''])[0]
    if path == BASE + '_2.asp':
        suffix = '?' + urlencode({'late': late, 'mode': mode})
        frames = [f'<frame name="receipt-header" src="{BASE}_2_3.asp{suffix}">', f'<frame name="receipt-data" src="{BASE}_2_2.asp{suffix}">']
        if args.get('reverse') == ['1']:
            frames.reverse()
        return '<!doctype html><html><head><title>架空レシート照会</title></head><frameset rows="160,*">' + ''.join(frames) + '</frameset></html>'
    if path == BASE + '_2_3.asp':
        rows = [('店舗', '(000000)架空店舗'), ('日付', '2026/10/18 00:00:00 ～ 2026/10/18 99:59:59'), ('業務区分', '販売業務'), ('年度', ''), ('シーズン', ''), ('カテゴリー', ''), ('ブランド', ''), ('サブブランド', ''), ('アイテム', ''), ('担当者', ''), ('レシートNo.', ''), ('JAN', ''), ('作成日付', '2026/10/18 14:00:0' + page + ' 現在')]
        groups = [rows[index:index + 3] for index in range(0, 12, 3)] + [rows[12:]]
        header = '<table id="receipt-summary" width="800">' + ''.join('<tr>' + ''.join(f'<td class="selecttitle">{name}</td><td>{value}</td>' for name, value in group) + '</tr>' for group in groups) + '</table>'
        options = ''.join(f'<option value="{value}"' + (' selected' if value == page else '') + f'>{value}</option>' for value in ['1', '2'])
        action = BASE + '_2_3.asp?mode=' + mode
        js = "top.fixturePagerWindow=window.name;top.fixturePagerClicks=(top.fixturePagerClicks||0)+1;top.frames['receipt-data'].location.href='" + BASE + "_2_2.asp?page='+this.form.PgSelect.value;this.form.submit();return false"
        if mode == 'retain-header':
            js = "top.fixturePagerWindow=window.name;top.fixturePagerClicks=(top.fixturePagerClicks||0)+1;top.frames['receipt-data'].location.href='" + BASE + "_2_2.asp?page='+this.form.PgSelect.value;return false"
        pager = f'''<form id="receipt-pager" name="form1" method="post" action="{action}" target="receipt-header">
        <input type="hidden" name="unchanged" value="FICTIONAL-RECEIPT-TOKEN"><input type="hidden" name="PgMax" value="2">
        <select name="PgSelect">{options}</select><input type="button" name="hyouzi" value="表示" onclick="{js}"></form>'''
        request = json.dumps({'method': method, 'values': values or {}})
        script = f'''window.fixtureReceiptRequest={request};window.fixtureHeaderOriginals={{form:document.getElementById('receipt-pager'),summary:document.getElementById('receipt-summary')}};'''
        content = header + pager
        if late == 'header':
            encoded = json.dumps(content, ensure_ascii=False).replace('</', '<\\/')
            return shell('<div id="receipt-header-build"></div>', f"setTimeout(()=>{{document.getElementById('receipt-header-build').innerHTML={encoded};{script}}},160)")
        return shell(content, script)
    if path == BASE + '_2_2.asp':
        if mode == 'empty':
            return shell('<p id="receipt-empty">該当データがありません。</p>')
        data = '''<form id="receipt-data-form" method="post" action="/fixture/receipt-action" target="receipt-data">
        <input type="hidden" name="original" value="FICTIONAL-DATA-TOKEN"><table id="receipt-table" width="1050"><tbody>
        <tr><th>No</th><th>時間</th><th>店舗</th><th>レシートNo.</th><th>詳細</th></tr>'''
        for index in range(1, 4):
            data += f'''<tr><td>{index}</td><td>2026/10/18 12:00:00</td><td>000000</td><td>FICTIONAL-PAGE{page}-{index}</td>
            <td><input type="button" name="detail" value="詳細" onclick="window.fixtureDetailClicks++;top.fixtureDetailWindow=window.name;return false"></td></tr>'''
        data += '</tbody></table></form>'
        script = '''window.fixtureDetailClicks=0;window.fixtureDataOriginals={form:document.getElementById('receipt-data-form'),table:document.getElementById('receipt-table'),button:document.querySelector('input[name=detail]')};window.fixtureOriginalDetailHandler=fixtureDataOriginals.button.onclick;'''
        if late == 'data':
            encoded = json.dumps(data, ensure_ascii=False).replace('</', '<\\/')
            return shell('<div id="receipt-data-build"></div>', f"setTimeout(()=>{{document.getElementById('receipt-data-build').innerHTML={encoded};{script}}},160)")
        return shell(data, script)
    return None


if __name__ == '__main__':
    fixtures = {}
    for late in ['', 'header', 'data']:
        for mode in ['', 'retain-header']:
            for reverse in ['', '1']:
                query = urlencode({'late': late, 'mode': mode, 'reverse': reverse})
                fixtures[BASE + '_2.asp?' + query] = response(BASE + '_2.asp', query)
                for suffix in ['2_3', '2_2']:
                    branch_query = urlencode({'late': late, 'mode': mode})
                    fixtures[BASE + '_' + suffix + '.asp?' + branch_query] = response(BASE + '_' + suffix + '.asp', branch_query)
    print(json.dumps(fixtures, ensure_ascii=False))
