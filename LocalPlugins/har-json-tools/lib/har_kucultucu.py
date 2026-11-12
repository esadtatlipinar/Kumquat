#!/usr/bin/env python3
"""Local HAR utility; Python standard library only."""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import webbrowser

STATIC_EXT = re.compile(r'\.(?:m?js|cjs|css|map|svg|png|jpe?g|gif|webp|avif|ico|bmp|woff2?|ttf|otf|eot|mp[34]|webm|ogg|wav|wasm)(?:$)', re.I)
TRACKERS = ('google-analytics.com', 'googletagmanager.com', 'nr-data.net', 'newrelic.com', 'mixpanel.com', 'mxpnl.com', 'visilabs.net', 'hotjar.com', 'hotjar.io', 'pendo.io', 'doubleclick.net', 'events.split.io', 'firebaselogging-pa.googleapis.com')


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')


def exclusive_output(source, suffix, extension):
    number = 1
    while True:
        numbered_suffix = suffix if number == 1 else f'{suffix}_{number}'
        target = source.with_name(source.stem + numbered_suffix + extension)
        try:
            return target, target.open('xb')
        except FileExistsError:
            number += 1


def write_output(source, suffix, extension, payload):
    target, handle = exclusive_output(source, suffix, extension)
    try:
        with handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    return target

def exclusion(entry):
    request = entry.get('request') or {}
    response = entry.get('response') or {}
    url = urlsplit(request.get('url') or '')
    host = (url.hostname or '').lower()
    path = url.path.lower()
    content = response.get('content') or {}
    mime = (content.get('mimeType') or '').lower().split(';')[0].strip()
    kind = (entry.get('_resourceType') or '').lower()
    if url.scheme in ('blob', 'data'):
        return 'Blob / data'
    if any(host == domain or host.endswith('.' + domain) for domain in TRACKERS) or host.startswith('telemetry.'):
        return 'Telemetri / takip'
    if re.search(r'/(?:telemetry|newrelic|activitylog)(?:/|$)', path) or (host == 'firebaseremoteconfig.googleapis.com' and 'fireperf' in path):
        return 'Telemetri / takip'
    if kind in ('script', 'stylesheet', 'image', 'font', 'media', 'ping') or STATIC_EXT.search(path):
        return 'Statik dosya'
    if mime.startswith(('image/', 'font/', 'audio/', 'video/')) or mime in ('text/css', 'application/wasm') or 'javascript' in mime or 'ecmascript' in mime or 'font-woff' in mime:
        return 'Statik dosya'
    if path.rsplit('/', 1)[-1] in ('remoteentry.json', 'federation.manifest.json'):
        return 'JavaScript modül listesi'
    # Preserve unknown requests and third-party functional APIs, including auth,
    # notification services, WebSockets, preflights, errors and redirects.
    return None

def compress(source, remove_html=False):
    source = Path(source)
    if source.suffix.lower() != '.har' or not source.is_file():
        raise ValueError('Lütfen mevcut bir .har dosyası seçin.')
    raw = source.read_bytes()
    data = json.loads(raw.decode('utf-8-sig'))
    if not isinstance(data, dict) or not isinstance(data.get('log'), dict) or not isinstance(data['log'].get('entries'), list):
        raise ValueError('Dosya geçerli bir HAR yapısı içermiyor.')
    entries = data['log']['entries']
    kept = []
    removed = collections.Counter()
    html_count = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError('HAR içinde geçersiz istek kaydı var.')
        reason = exclusion(entry)
        if reason:
            removed[reason] += 1
            continue
        if remove_html:
            content = (entry.get('response') or {}).get('content') or {}
            if 'html' in (content.get('mimeType') or '').lower() and 'text' in content:
                content.pop('text', None)
                content.pop('encoding', None)
                html_count += 1
        kept.append(entry)
    data['log']['entries'] = kept
    result = json_bytes(data)
    assert json.loads(result) == data
    target = write_output(source, '_compressed', '.har', result)
    return {'path': str(target), 'name': target.name, 'before': len(raw), 'after': len(result), 'total': len(entries), 'kept': len(kept), 'removed': sum(removed.values()), 'reasons': dict(removed), 'html_removed': html_count}


def is_tag_assistant_export(root):
    if not isinstance(root, dict) or not isinstance(root.get('data'), dict):
        return False
    containers = root['data'].get('containers')
    if not isinstance(containers, list):
        return False
    return all(
        isinstance(container, dict)
        and isinstance(container.get('messages', []), list)
        and isinstance(container.get('tagsFired', {}), dict)
        and all(isinstance(records, list) for records in container.get('tagsFired', {}).values())
        for container in containers
    )


def tag_assistant_llm_document(root, source, raw):
    records = {}
    record_by_json = {}
    origins = {}
    memberships = collections.defaultdict(list)

    def record_ref(record, origin):
        canonical = json.dumps(record, ensure_ascii=False, separators=(',', ':'), sort_keys=True, allow_nan=False)
        existing = record_by_json.get(canonical)
        if existing:
            return existing
        record_id = f'r{len(records) + 1:04d}'
        record_by_json[canonical] = record_id
        records[record_id] = record
        origins[record_id] = origin
        return record_id

    indexed_containers = []
    for container_index, container in enumerate(root['data']['containers']):
        metadata = {key: value for key, value in container.items() if key not in ('messages', 'tagsFired')}
        message_refs = [
            record_ref(record, {'containerIndex': container_index, 'messageIndex': message_index})
            for message_index, record in enumerate(container.get('messages', []))
        ]
        tags_fired_refs = {}
        for tag_name, tag_records in container.get('tagsFired', {}).items():
            refs = []
            for tag_index, record in enumerate(tag_records):
                record_id = record_ref(record, {
                    'containerIndex': container_index,
                    'tagName': tag_name,
                    'tagIndex': tag_index,
                })
                refs.append(record_id)
                memberships[record_id].append({
                    'containerIndex': container_index,
                    'tagName': tag_name,
                    'tagIndex': tag_index,
                })
            tags_fired_refs[tag_name] = refs
        indexed_containers.append({
            'index': container_index,
            'publicId': container.get('publicId'),
            'fieldOrder': list(container),
            'meta': metadata,
            'messageRefs': message_refs,
            'tagsFiredRefs': tags_fired_refs,
        })

    public_ids = {entry['index']: entry['publicId'] for entry in indexed_containers}
    catalog = []
    for record_id, record in records.items():
        origin = origins[record_id]
        catalog.append({
            'id': record_id,
            'bytes': len(json_bytes(record)),
            'containerIndex': origin['containerIndex'],
            'publicId': public_ids[origin['containerIndex']],
            'messageIndex': origin.get('messageIndex'),
            'eventId': record.get('eventId') if isinstance(record, dict) else None,
            'eventName': record.get('eventName') if isinstance(record, dict) else None,
            'eventNameKey': record.get('eventNameKey') if isinstance(record, dict) else None,
            'title': record.get('title') if isinstance(record, dict) else None,
            'firedAs': [item['tagName'] for item in memberships[record_id]],
        })

    message_count = sum(len(entry['messageRefs']) for entry in indexed_containers)
    fired_count = sum(
        len(refs)
        for entry in indexed_containers
        for refs in entry['tagsFiredRefs'].values()
    )
    document = {
        'format': 'tag-assistant-lossless-llm-v1',
        'llmGuide': {
            'lossless': True,
            'summary': 'Complete Tag Assistant export with repeated records stored once.',
            'howToRead': [
                'Search catalog by eventName, title, publicId or firedAs.',
                'Open the full payload at records[catalog item id].',
                'index.containers[].messageRefs preserves message order.',
                'index.containers[].tagsFiredRefs preserves tag membership and order.',
            ],
        },
        'source': {
            'filename': source.name,
            'bytes': len(raw),
            'sha256': hashlib.sha256(raw).hexdigest(),
        },
        'counts': {
            'containers': len(indexed_containers),
            'messageRefs': message_count,
            'tagsFiredRefs': fired_count,
            'uniqueRecords': len(records),
            'duplicateRecordsRemoved': message_count + fired_count - len(records),
        },
        'index': {
            'topLevelOrder': list(root),
            'topLevelMeta': {key: value for key, value in root.items() if key != 'data'},
            'dataFieldOrder': list(root['data']),
            'dataMeta': {key: value for key, value in root['data'].items() if key != 'containers'},
            'containers': indexed_containers,
        },
        'catalog': catalog,
        'records': records,
    }
    return document


def reconstruct_tag_assistant(document):
    records = document['records']
    index = document['index']
    containers = []
    for entry in index['containers']:
        container = {}
        for key in entry['fieldOrder']:
            if key == 'messages':
                container[key] = [records[record_id] for record_id in entry['messageRefs']]
            elif key == 'tagsFired':
                container[key] = {
                    tag_name: [records[record_id] for record_id in refs]
                    for tag_name, refs in entry['tagsFiredRefs'].items()
                }
            else:
                container[key] = entry['meta'][key]
        containers.append(container)
    data = {
        key: containers if key == 'containers' else index['dataMeta'][key]
        for key in index['dataFieldOrder']
    }
    return {
        key: data if key == 'data' else index['topLevelMeta'][key]
        for key in index['topLevelOrder']
    }


def prepare_llm_json(source):
    source = Path(source)
    if source.suffix.lower() != '.json' or not source.is_file():
        raise ValueError('Lütfen mevcut bir .json dosyası seçin.')
    raw = source.read_bytes()
    try:
        root = json.loads(raw.decode('utf-8-sig'))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError(f'Dosya geçerli JSON içermiyor: {exc}') from exc

    if is_tag_assistant_export(root):
        document = tag_assistant_llm_document(root, source, raw)
        reconstructed = reconstruct_tag_assistant(document)
        if reconstructed != root:
            raise RuntimeError('Kayıpsızlık doğrulaması başarısız oldu; çıktı yazılmadı.')
        mode = 'Tag Assistant · kayıpsız tekrar kaldırma'
        counts = document['counts']
    else:
        document = {
            'format': 'generic-json-lossless-llm-v1',
            'llmGuide': {
                'lossless': True,
                'summary': 'Whitespace-free JSON. The complete original JSON value is in data.',
            },
            'source': {
                'filename': source.name,
                'bytes': len(raw),
                'sha256': hashlib.sha256(raw).hexdigest(),
            },
            'data': root,
        }
        if document['data'] != root:
            raise RuntimeError('Kayıpsızlık doğrulaması başarısız oldu; çıktı yazılmadı.')
        mode = 'Genel JSON · kayıpsız minify'
        counts = {'duplicateRecordsRemoved': 0, 'uniqueRecords': 0}

    result = json_bytes(document)
    # Parse the exact bytes that will be written before touching the filesystem.
    if json.loads(result) != document:
        raise RuntimeError('Çıktı doğrulaması başarısız oldu; çıktı yazılmadı.')
    target = write_output(source, '_llm_ready', '.json', result)
    return {
        'kind': 'json',
        'mode': mode,
        'path': str(target),
        'name': target.name,
        'before': len(raw),
        'after': len(result),
        'duplicates': counts['duplicateRecordsRemoved'],
        'records': counts['uniqueRecords'],
        'lossless': True,
    }

PAGE = Path(__file__).with_name('arayuz.html')

def serve():
    token = secrets.token_urlsafe(32)
    selected = set()
    outputs = set()
    operation_lock = threading.Lock()
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def send_json(self, value, status=200):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)
        def do_GET(self):
            if self.path != '/' + token + '/':
                self.send_error(404)
                return
            body = PAGE.read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Frame-Options', 'DENY')
            self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
            self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            prefix = '/' + token + '/'
            origin = self.headers.get('Origin')
            expected_origin = f'http://127.0.0.1:{self.server.server_port}'
            if not self.path.startswith(prefix) or (origin and origin != expected_origin) or self.headers.get('X-HAR-Local') != '1':
                self.send_json({'error': 'Geçersiz yerel istek.'}, 403)
                return
            if not operation_lock.acquire(blocking=False):
                self.send_json({'error': 'Başka bir işlem sürüyor.'}, 409)
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if length > 16384 or length < 0:
                    raise ValueError('İstek çok büyük.')
                params = json.loads(self.rfile.read(length) or b'{}')
                action = self.path[len(prefix):]
                if action == 'choose':
                    script = 'POSIX path of (choose file with prompt "HAR veya JSON dosyasını seçin")'
                    proc = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
                    if proc.returncode:
                        if '-128' in proc.stderr:
                            self.send_json({'cancelled': True})
                            return
                        raise ValueError('Dosya seçici açılamadı: ' + proc.stderr.strip())
                    path = Path(proc.stdout.strip()).resolve()
                    if path.suffix.lower() not in ('.har', '.json') or not path.is_file():
                        raise ValueError('Lütfen .har veya .json uzantılı bir dosya seçin.')
                    selected.add(str(path))
                    self.send_json({
                        'path': str(path),
                        'name': path.name,
                        'bytes': path.stat().st_size,
                        'kind': path.suffix.lower()[1:],
                    })
                elif action == 'process':
                    path = params.get('path')
                    if path not in selected:
                        raise ValueError('Önce arayüzden bir dosya seçin.')
                    if Path(path).suffix.lower() == '.har':
                        result = compress(path, remove_html=params.get('remove_html') is True)
                        result['kind'] = 'har'
                    else:
                        result = prepare_llm_json(path)
                    outputs.add(result['path'])
                    self.send_json(result)
                elif action == 'reveal':
                    path = params.get('path')
                    if path not in outputs:
                        raise ValueError('Çıktı bulunamadı.')
                    subprocess.run(['open', '-R', path], check=True)
                    self.send_json({'ok': True})
                else:
                    self.send_json({'error': 'İşlem bulunamadı.'}, 404)
            except Exception as exc:
                self.send_json({'error': str(exc)}, 400)
            finally:
                operation_lock.release()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    url = f'http://127.0.0.1:{server.server_port}/{token}/'
    print('HAR + JSON Sadeleştirici çalışıyor. Kapatmak için bu pencereyi kapatın veya Ctrl+C kullanın.', flush=True)
    print(url, flush=True)
    webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Yerel HAR küçültücü ve JSON LLM hazırlayıcı')
    parser.add_argument('--compress', type=Path, help='Arayüz olmadan dosyayı küçült')
    parser.add_argument('--llm-ready', type=Path, help='JSON dosyasını tek dosyalık kayıpsız LLM-ready çıktıya dönüştür')
    parser.add_argument('--remove-html', action='store_true')
    args = parser.parse_args()
    if args.compress and args.llm_ready:
        parser.error('--compress ile --llm-ready birlikte kullanılamaz')
    if args.compress:
        print(json.dumps(compress(args.compress, args.remove_html), ensure_ascii=False))
    elif args.llm_ready:
        print(json.dumps(prepare_llm_json(args.llm_ready), ensure_ascii=False))
    else:
        serve()
