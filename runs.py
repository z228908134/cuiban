import json, sys

d = json.load(open('runs.json', encoding='utf-8'))
lines = []
for r in d.get('workflow_runs', []):
    lines.append('%s %s %s %s %s %s' % (
        r['run_number'], r['status'], r['conclusion'],
        r['head_sha'][:7], r['created_at'], r['id']))
open('runs.txt', 'w', encoding='utf-8').write('\n'.join(lines) or 'none')
print('\n'.join(lines) or 'none')