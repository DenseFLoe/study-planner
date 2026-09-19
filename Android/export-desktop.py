#!/usr/bin/env python3
"""Read a transactionally consistent desktop snapshot, including the SQLite WAL."""
import datetime, hashlib, json, pathlib, sqlite3
root = pathlib.Path(__file__).resolve().parent
source = pathlib.Path.home() / 'Library/Application Support/StudyPlanner/StudyPlanner.store'
(root / 'backups').mkdir(exist_ok=True)
(root / 'assets').mkdir(exist_ok=True)
with sqlite3.connect(source.as_uri() + '?mode=ro', uri=True) as src:
    with sqlite3.connect(root / 'backups/desktop-snapshot.store') as snapshot:
        src.backup(snapshot)
        state = dict(schemaVersion=1, courses=[], fixedEvents=[], tasks=[], completions=[])
        names = dict(course='courses', fixed='fixedEvents', task='tasks', completion='completions')
        for kind, payload in snapshot.execute('SELECT ZKIND, ZPAYLOAD FROM ZLOCALRECORD'):
            if kind == 'sync':
                continue
            value = json.loads(payload)
            if kind == 'settings':
                assert value['version'] == 1
                state['settings'] = value['settings']
            else:
                state[names[kind]].append(value)
assert 'settings' in state
state['tasks'].sort(key=lambda task: task['start'])
content = json.dumps(state, ensure_ascii=False, separators=(',', ':')).encode()
(root / 'assets/initial-state.json').write_bytes(content)
metadata = dict(exportedAt=datetime.datetime.now().astimezone().isoformat(),
                counts={key:len(state[key]) for key in names.values()},
                sha256=hashlib.sha256(content).hexdigest())
(root / 'assets/snapshot-info.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2))
print(json.dumps(metadata, ensure_ascii=False, indent=2))
