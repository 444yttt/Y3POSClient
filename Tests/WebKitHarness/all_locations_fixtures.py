"""Fictional all-location stock: source rows/forms mirror the legacy report layout."""
import json
from urllib.parse import parse_qs

BASE = '/scripts/verona/print/prtz450'
SEARCH = {}
DETAIL = {}


def page(body, script=''):
    return '<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空全拠点在庫照会</title><style>body{font:12px serif;margin:8px}td,th{border:1px solid #aaa;padding:4px;white-space:nowrap}</style></head><body>'+body+'<script>'+script+'</script></body></html>'


def header():
    return page('''<table id="all-location-summary" width="850">
    <tr><td>品番／商品</td><td colspan="3">MOCK-ALL001</td><td>カラー</td><td></td><td>サイズ</td><td></td></tr>
    <tr><td>JANコード</td><td colspan="3"></td><td>副商品番号</td><td colspan="3"></td></tr>
    <tr><td>カテゴリー</td><td></td><td>アイテム</td><td></td><td>ブランド</td><td colspan="3"></td></tr>
    <tr><td>年度</td><td></td><td>シーズン</td><td></td><td>商品名</td><td colspan="3"></td></tr>
    <tr><td>地区</td><td colspan="7"></td></tr><tr><td>作成日付</td><td colspan="7">2026/10/23 12:00:00 現在</td></tr></table>''')


def response(path, query='', method='GET', values=None):
    global SEARCH, DETAIL
    values = values or {}
    if path == BASE+'_1.asp':
        if method == 'POST':
            SEARCH = values
            return page('', "location.replace('prtz450_2.asp')")
        return '<!doctype html><html><head><title>架空全拠点在庫照会</title></head><frameset rows="55,*"><frame src="prtz450_1_1.asp"><frame name="all-search" src="prtz450_1_2.asp"></frameset></html>'
    if path in [BASE+'_1_1.asp', BASE+'_2_1.asp', BASE+'_3_1.asp']:
        return page('<a href="prtz450_1.asp" target="_top">検索条件</a>')
    if path == BASE+'_1_2.asp':
        return page('''<form id="all-location-search" name="form1" method="post" action="prtz450_1.asp" target="_top">
        <input type="hidden" name="unchanged" value="FICTIONAL-SEARCH-TOKEN"><table width="850"><tr><td>品番／商品</td><td><input type="text" name="ft_goods_code"></td></tr></table>
        <input type="button" name="ken" value="検索" onclick="this.form.submit()"></form>''')
    if path == BASE+'_2.asp':
        return '<!doctype html><html><head><title>架空全拠点在庫照会</title></head><frameset rows="55,160,*"><frame src="prtz450_2_1.asp"><frame name="all-metadata" src="prtz450_2_3.asp"><frame name="all-data" src="prtz450_2_2.asp"></frameset></html>'
    if path in [BASE+'_2_3.asp',BASE+'_3_3.asp']:
        body = header()
        if path == BASE+'_2_3.asp':
            body = body.replace('</body>','''<form id="all-list-pager" method="post" action="prtz450_2_3.asp" target="all-metadata"><input type="hidden" name="PgMax" value="1"><select name="PgSelect"><option value="1">1</option></select><input type="button" name="hyouzi" value="表示" onclick="top.fixtureAllPager=(top.fixtureAllPager||0)+1"><input type="button" name="Front" value="前ページ" disabled><input type="button" name="Back" value="次ページ" disabled></form></body>''')
        return body
    if path == BASE+'_2_2.asp':
        return page('''<table id="all-location-products" width="750"><tr><th>品番</th><th>商品名</th><th>カラー</th><th>サイズ</th><th>詳細</th></tr>
        <tr><td>MOCK-ALL001</td><td>架空のシューズ</td><td>MOCK-COLOR</td><td>313〜317</td><td><form id="all-location-detail" method="post" action="prtz450_3.asp" target="_top"><input type="hidden" name="product" value="MOCK-ALL001"><input type="hidden" name="unchanged" value="FICTIONAL-DETAIL-TOKEN"><input type="submit" value="詳細"></form></td></tr></table>''', 'window.fixtureAllSearchFields='+json.dumps(SEARCH)+';window.fixtureOriginalDetailForm=document.getElementById("all-location-detail");')
    if path == BASE+'_3.asp':
        if method == 'POST':
            DETAIL = values
        return '<!doctype html><html><head><title>架空全拠点在庫照会</title></head><frameset rows="55,160,*"><frame src="prtz450_3_1.asp"><frame name="all-metadata" src="prtz450_3_3.asp"><frame name="all-data" src="prtz450_3_2.asp"></frameset></html>'
    if path == BASE+'_3_2.asp':
        rows = [('313','1','架空拠点A'),('317','0','架空拠点A'),('314','-1','架空拠点B'),('316','','架空拠点B')]
        table = '<table id="all-location-stock" width="1150"><tr>'+''.join('<th>'+label+'</th>' for label in ['品番','ｶﾗｰ','ｻｲｽﾞ','商品ｺｰﾄﾞ','商品名','地区','店舗','ＴＥＬ','上代','有効在庫数'])+'</tr>'
        for size, quantity, store in rows:
            table += '<tr>'+''.join('<td>'+value+'</td>' for value in ['MOCK-ALL001','MOCK-COLOR',size,'FICTIONAL-SKU-'+size,'架空のシューズ','架空地区',store,'000-000-0000','架空金額',quantity])+'</tr>'
        table += '<tr><td colspan="9">合計</td><td>006</td></tr></table>'
        back = '''<form method="post" action="prtz450_1.asp" target="_top"><input type="button" name="back" value="戻る" onclick="window.fixtureAllBackClicks++;history.back()"></form>'''
        return page(table+back, 'window.fixtureAllDetailFields='+json.dumps(DETAIL)+';window.fixtureAllBackClicks=0;window.fixtureOriginalStock=document.getElementById("all-location-stock");window.fixtureOriginalStockText=fixtureOriginalStock.textContent;window.fixtureStockData=()=>Array.from(fixtureOriginalStock.rows).map(row=>Array.from(row.cells).map(cell=>cell.textContent));')
    return None
