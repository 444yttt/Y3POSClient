"""Fictional control-only and navigation-only report leaves plus real datasets."""
from urllib.parse import parse_qs

BASE = '/scripts/verona/print/prtz094'
QUERY = '?scenario=pane-roles'


def page(body):
    return '<!doctype html><html lang="ja"><head><meta charset="utf-8"><title>架空帳票</title></head><body>' + body + '</body></html>'


def response(path, query='', method='GET', values=None):
    if parse_qs(query).get('scenario') != ['pane-roles']:
        return None
    action_base = '/scripts/verona/print/dstz100'
    if path == action_base + '_3.asp':
        return f'''<!doctype html><html><head><title>架空集計明細</title></head><frameset rows="55,*" cols="*">
        <frame name="role-navigation" src="{BASE}_2_3.asp{QUERY}">
        <frame name="role-data-with-back" src="{action_base}_3_2.asp{QUERY}"></frameset></html>'''
    if path == action_base + '_3_2.asp':
        metadata = '''<table id="role-action-metadata"><tr><td>品番</td><td>FICTIONAL-001</td><td>カラー</td><td>MOCKCOL</td><td>サイズ</td><td>317</td><td>商品名</td><td colspan="3">架空商品</td></tr>
        <tr><td>年度</td><td>2026</td><td>分類</td><td>架空</td><td>種類</td><td>架空</td><td>区分</td><td>架空</td><td>状態</td><td>架空</td></tr>
        <tr><td>作成日付</td><td colspan="9">2026/10/23 現在</td></tr></table>'''
        data = '<table id="role-data-with-back" width="1100">'
        cell_counts = [1, 2, 4, 4, 3, 2, 4, 6, 6, 5, 6, 6, 6, 3, 6, 2, 4, 2, 2, 2]
        for row, count in enumerate(cell_counts):
            data += '<tr>' + ''.join(f'<td>{"" if row in [4, 15] else str(row * 6 + column)}</td>' for column in range(count)) + '</tr>'
        data += '<tr><td colspan="6"><input id="role-original-back" name="back" type="button" value="戻る" onclick="window.fixtureOriginalBackCount=(window.fixtureOriginalBackCount||0)+1"></td></tr></table>'
        return page(metadata + data + '''<script>window.fixtureOriginalBack=document.getElementById('role-original-back');window.fixtureOriginalActionTable=document.getElementById('role-data-with-back');</script>''')
    if path == BASE + '_2.asp':
        return f'''<!doctype html><html><head><title>架空帳票</title></head><frameset rows="55,80,*,*" cols="*">
        <frame name="role-navigation" src="{BASE}_2_3.asp{QUERY}">
        <frame name="role-pager" src="{BASE}_2_2.asp{QUERY}">
        <frame name="role-data" src="{BASE}_2_1.asp{QUERY}">
        <frame name="role-aggregate" src="{BASE}_2_4.asp{QUERY}"></frameset></html>'''
    if path == BASE + '_2_3.asp':
        return page('<style>/*' + ('FICTIONAL STYLE TEXT ' * 100) + '*/</style><center><a href="/scripts/verona/menu/metz010_1.asp" target="_top">メニュー選択画面</a> <a href="prtz094_1.asp" target="_top">売上ベストレポート検索指定画面</a></center>')
    if path == BASE + '_2_2.asp':
        return page(f'''<table><tr><td class="selecttitle">作成日付</td><td>2026/10/23 12:00:00 現在</td></tr></table>
        <table><tr><td><form name="form1" method="post" action="{BASE}_2_2.asp{QUERY}" target="role-pager"><select name="PageNum"><option value="1">1</option></select><input name="submit3" type="submit" value="表示"></form></td>
        <td><form name="form1" method="post" action="{BASE}_2_2.asp{QUERY}" target="role-pager"><input name="submit1" type="submit" value="前ページ" disabled></form></td>
        <td><form name="form1" method="post" action="{BASE}_2_2.asp{QUERY}" target="role-pager"><input name="submit2" type="submit" value="次ページ" disabled></form></td></tr></table>''')
    if path == BASE + '_2_1.asp':
        return page('''<form id="readonly-output"><input type="text" name="reported_value" value="FICTIONAL" readonly></form>
        <table id="role-real-data" width="900"><tr><th>商品</th><th>数量</th><th>金額</th></tr>
        <tr><td>架空商品A</td><td>3</td><td>300</td></tr><tr><td>架空商品B</td><td>4</td><td>400</td></tr></table>''')
    if path == BASE + '_2_4.asp':
        return page('''<table id="role-aggregate-summary"><tr><td>店舗</td><td>架空店舗</td></tr><tr><td>作成日付</td><td>2026/10/23 現在</td></tr></table>
        <table id="role-real-aggregate"><tr><th>分類</th><th>数量</th></tr><tr><td>架空A</td><td>1</td></tr><tr><td>架空B</td><td>2</td></tr><tr><td>架空C</td><td>3</td></tr><tr><td>合計</td><td>6</td></tr></table>''')
    if path == BASE + '_1_3.asp':
        return page('<p id="role-no-data">該当するデータがありません。</p>')
    if path == BASE + '_1.asp':
        return f'<html><head></head><frameset rows="55,*"><frame name="role-navigation" src="{BASE}_2_3.asp{QUERY}"><frame name="empty-output" src="{BASE}_1_3.asp{QUERY}"></frameset></html>'
    return None
