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
    selected = (values or {}).get('PgSelect', (values or {}).get('PageNum', args.get('page', ['1'])))[-1]
    page = selected if selected in ['1', '2'] else '1'
    late = args.get('late', [''])[0]
    mode = args.get('mode', [''])[0]
    if mode == 'unnamed-page-num':
        mapped = dict(args)
        mapped['mode'] = ['page-num']
        content = response(path, urlencode(mapped, doseq=True), method, values)
        if content is not None:
            content = content.replace('mode=page-num', 'mode=unnamed-page-num')
            for name in ['submit3', 'submit1', 'submit2']:
                content = content.replace(f' name="{name}"', '')
        return content
    if mode == 'inline-ranking':
        if path == BASE + '_1.asp':
            return f'''<!doctype html><html><head><title>架空ランキング</title></head><frameset rows="115,*">
            <frame name="summary-condition" src="{BASE}_1_1.asp?mode=page-num"><frame name="summary-report" src="{BASE}_2.asp?mode=inline-ranking"></frameset></html>'''
        if path == BASE + '_2.asp':
            request = json.dumps({'method': method, 'values': values or {}})
            return f'''<!doctype html><html><head><title>架空ランキング</title><script>window.fixtureSummaryPost={request};</script></head>
            <frameset rows="*"><frame name="ranking-data" src="{BASE}_2_2.asp?mode=inline-ranking&page={page}"></frameset></html>'''
        if path == BASE + '_2_2.asp':
            summary = response(BASE + '_2_3.asp', urlencode({'mode': 'page-num', 'page': page}))
            heading = '<tr>' + ''.join(f'<th>架空列{column}</th>' for column in range(9)) + '</tr>'
            rows = ''.join('<tr>' + ''.join(f'<td>{row * 9 + column}</td>' for column in range(9)) + '</tr>' for row in range(6))
            hidden = ''.join(f'<input type="hidden" name="ranking_key" value="FICTIONAL-{index}">' for index in range(20))
            ranking = f'<form id="ranking-original-form" method="post"><table id="ranking-original-table">{heading}{rows}</table></form>'
            # Legacy ranking rows carry repeated hidden keys inside source cells.
            ranking = ranking.replace('<td>0</td>', '<td>0' + hidden + '</td>', 1)
            return summary.replace('mode=page-num', 'mode=inline-ranking').replace('</body>', ranking + '</body>')
    if mode == 'page-num':
        if path == BASE + '_1.asp':
            return f'''<!doctype html><html><head><title>架空集計一覧</title></head><frameset rows="115,*">
            <frame name="summary-condition" src="{BASE}_1_1.asp?mode=page-num"><frame name="summary-report" src="{BASE}_2.asp?mode=page-num"></frameset></html>'''
        if path == BASE + '_1_1.asp':
            return shell('''<form><label>架空の日付<input type="text" name="ft_YYYYMMDD_F" maxlength="8" value="20261023"></label></form>
            <div id="ui-datepicker-div"><table class="ui-datepicker-calendar"><tr><th>日</th><th>月</th><th>火</th></tr><tr><td>1</td><td>2</td><td>3</td></tr></table></div>''')
        if path == BASE + '_2.asp':
            request = json.dumps({'method': method, 'values': values or {}})
            return f'''<!doctype html><html><head><title>架空集計一覧</title><script>window.fixtureSummaryPost={request};</script></head>
            <frameset rows="80,*"><frame name="receipt-header" src="{BASE}_2_3.asp?mode=page-num&page={page}">
            <frame name="receipt-data" src="{BASE}_2_2.asp?mode=page-num&page={page}"></frameset></html>'''
        if path == BASE + '_2_3.asp':
            options = ''.join(f'<option value="{value}"' + (' selected' if value == page else '') + f'>{value}</option>' for value in ['1', '2'])
            action = BASE + '_2.asp?mode=page-num'
            previous = ' disabled' if page == '1' else ''
            following = ' disabled' if page == '2' else ''
            return shell(f'''<table id="created-only-summary"><tr><td class="selecttitle">作成日付</td><td>2026/10/23 12:00:0{page} 現在</td></tr></table>
            <table><tr><td><form name="form1" id="summary-show" method="post" action="{action}" target="summary-report">
            <input type="hidden" name="token" value="FICTIONAL-SHOW"><select name="PageNum">{options}</select><input type="submit" name="submit3" value=" 表示 "></form></td>
            <td><form name="form1" id="summary-previous" method="post" action="{action}" target="summary-report">
            <input type="hidden" name="token" value="FICTIONAL-PREVIOUS"><input type="hidden" name="PageNum" value="1"><input type="submit" name="submit1" value="前ページ"{previous}></form></td>
            <td><form name="form1" id="summary-next" method="post" action="{action}" target="summary-report">
            <input type="hidden" name="token" value="FICTIONAL-NEXT"><input type="hidden" name="PageNum" value="2"><input type="submit" name="submit2" value="次ページ"{following}></form></td></tr></table>''', '''
            window.fixtureSummaryOriginals=Array.from(document.forms).map(form=>({form,fields:Array.from(form.elements),target:form.target,action:form.action}));''')
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
