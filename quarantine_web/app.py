"""Quarantine review UI. Run only on a trusted LAN; use a TLS reverse proxy if needed."""
import os, secrets, time, json, re, tempfile, threading, fcntl
from datetime import date as date_type
from pathlib import Path
from functools import wraps
import requests
from flask import Flask, request, session, redirect, url_for, abort, render_template_string, Response

ROOT = Path(os.environ.get('PAPERLESS_STATE_DIR', '/media/BlueDisc3/PAPERLESS/state'))
PROPOSALS = ROOT / 'metadata' / 'proposals'
JOBS = ROOT / 'jobs'
PAPERLESS = os.environ.get('PAPERLESS_URL', 'http://rasp2:1888').rstrip('/')
app = Flask(__name__)
app.secret_key = os.environ['QUARANTINE_SESSION_SECRET']
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE='Strict', PERMANENT_SESSION_LIFETIME=1800)
TOKENS = {}  # session ID -> (token, expiry); not persisted, never sent to browser
LOCK = threading.RLock()

BASE = '''<!doctype html><html lang="de"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Paperless Quarantäne</title><style>body{font:16px system-ui;max-width:960px;margin:35px auto;padding:0 18px;color:#24313d}input,textarea,button{font:inherit;padding:8px;margin:5px 0;max-width:100%}input[type=text],input[type=password],textarea{width:95%}textarea{min-height:85px}article{padding:15px;border:1px solid #cbd5e1;border-radius:8px;margin:14px 0}label{display:block;margin-top:10px}button{cursor:pointer}small{color:#64748b}a{color:#1261a0}</style><h1>Paperless – Quarantäne</h1>{% if logged %}<p><a href="{{url_for('index')}}">Übersicht</a> · <a href="{{url_for('logout')}}">Abmelden</a></p>{% endif %}{{body|safe}}</html>'''

def page(body, **kwargs):
    return render_template_string(BASE, body=render_template_string(body, **kwargs), logged=bool(session.get('sid')))

def require_login(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        sid=session.get('sid')
        with LOCK:
            token, expiry = TOKENS.get(sid, ('', 0))
        if not token or expiry < time.time():
            session.clear()
            return redirect(url_for('login'))
        return fn(*args, **kwargs)
    return wrapper

def token():
    return TOKENS[session['sid']][0]

def csrf():
    if not secrets.compare_digest(request.form.get('csrf',''), session.get('csrf','')):
        abort(403)

def read_job(path):
    data={}
    for line in path.read_text().splitlines():
        if '=' in line:
            k,v=line.split('=',1)
            if k in ('STATUS','PAPERLESS_DOCUMENT_ID','JOB_ID'):
                data[k]=v.strip().strip("'\"")
    return data

def job_for_doc(doc_id):
    for path in JOBS.glob('*/job.conf'):
        data=read_job(path)
        if data.get('PAPERLESS_DOCUMENT_ID')==str(doc_id) and data.get('STATUS')=='QUARANTINE':
            return path
    return None

def save_json(path, data):
    path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(dir=path.parent,prefix='.review-',suffix='.json')
    try:
        with os.fdopen(fd,'w') as f:
            json.dump(data,f,ensure_ascii=False,indent=2)
            f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)


def archive_cron_lock():
    """Share the same flock as script 03 so review writes cannot race the archiver."""
    lock_path = ROOT / '.03_archive_to_gdrive.sh.lock'
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = open(lock_path, 'a+')
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle

@app.route('/login', methods=['GET','POST'])
def login():
    error=''
    if request.method=='POST':
        try:
            resp=requests.post(PAPERLESS+'/api/token/',json={'username':request.form['username'],'password':request.form['password']},timeout=15)
            resp.raise_for_status()
            api_token=resp.json().get('token','')
            if not api_token: raise ValueError('Kein Token')
            sid=secrets.token_urlsafe(32)
            with LOCK:TOKENS[sid]=(api_token,time.time()+1800)
            session.clear();session['sid']=sid;session['csrf']=secrets.token_urlsafe(32)
            return redirect(url_for('index'))
        except (requests.RequestException,ValueError,KeyError):
            error='Anmeldung fehlgeschlagen oder Paperless-Token-Endpunkt nicht verfügbar.'
    return page('''<p>Mit bestehenden Paperless-Zugangsdaten anmelden.</p><p>{{error}}</p><form method="post"><label>Benutzername<input name="username" required></label><label>Passwort<input type="password" name="password" required></label><button>Anmelden</button></form>''',error=error)

@app.route('/logout')
def logout():
    sid=session.get('sid')
    with LOCK:TOKENS.pop(sid,None)
    session.clear();return redirect(url_for('login'))

@app.route('/')
@require_login
def index():
    rows=[]
    for job in JOBS.glob('*/job.conf'):
        info=read_job(job)
        if info.get('STATUS')!='QUARANTINE':continue
        did=info.get('PAPERLESS_DOCUMENT_ID','')
        if not did.isdigit():continue
        proposal=PROPOSALS/f'{did}.json'
        if not proposal.is_file():continue
        try: data=json.loads(proposal.read_text())
        except (ValueError,OSError):continue
        rows.append({'id':did,'category':data.get('proposal',{}).get('primary_tag',''),'reason':data.get('proposal',{}).get('reason','')})
    return page('''<p>{{rows|length}} Dokumente zur Prüfung.</p>{% for r in rows %}<article><a href="{{url_for('review',did=r.id)}}">Dokument {{r.id}}</a> – {{r.category}}<p><small>{{r.reason}}</small></p></article>{% endfor %}''',rows=rows)

@app.route('/review/<int:did>',methods=['GET','POST'])
@require_login
def review(did):
    path=PROPOSALS/f'{did}.json'
    if not path.is_file():abort(404)
    with LOCK:
        job=job_for_doc(did)
        if not job:abort(404)
        data=json.loads(path.read_text()); prop=data.get('proposal',{})
        if request.method=='POST':
            csrf()
            primary=request.form.get('primary','').strip()
            if not primary or len(primary)>120:abort(400)
            tags=[x.strip() for x in request.form.get('tags','').split(',') if x.strip()]
            if len(tags)>30 or any(len(t)>120 for t in tags):abort(400)
            corr=request.form.get('correspondent','').strip()
            date_value=request.form.get('date','').strip()
            if len(corr)>180:abort(400)
            if date_value:
                try:
                    if date_type.fromisoformat(date_value).isoformat() != date_value: abort(400)
                except ValueError:
                    abort(400)
            prop.update(primary_tag=primary,additional_tags=tags,correspondent_suggestion=corr or None,document_date=date_value,requires_review=False,review_decision='no_check_needed',validation_warnings=[])
            shared_lock = archive_cron_lock()
            if shared_lock is None:
                return page("""<p>Die Archivierung läuft gerade. Bitte in wenigen Sekunden erneut versuchen.</p><p><a href="{{url_for('review',did=did)}}">Zurück zur Prüfung</a></p>""", did=did), 409
            try:
                # Jobstatus erneut unter dem gemeinsamen Lock prüfen.
                current_job = read_job(job)
                if current_job.get('STATUS') != 'QUARANTINE':
                    abort(409, 'Job ist nicht mehr in Quarantäne.')
                data['proposal']=prop;data['applied']=False
                data['manual_review']={'approved_at':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'approved_by':'paperless-authenticated'}
                save_json(path,data)
                original=job.read_text(); updated=re.sub(r'(?m)^STATUS=.*$', 'STATUS=REVIEW_APPROVED',original,count=1)
                if updated==original:abort(500)
                fd,tmp=tempfile.mkstemp(dir=job.parent,prefix='.review-job-')
                try:
                    with os.fdopen(fd,'w') as f:f.write(updated);f.flush();os.fsync(f.fileno())
                    os.replace(tmp,job)
                finally:
                    if os.path.exists(tmp):os.unlink(tmp)
            finally:
                fcntl.flock(shared_lock.fileno(), fcntl.LOCK_UN)
                shared_lock.close()
            return redirect(url_for('index'))
    return page('''<article><h2>Dokument {{did}}</h2><p>{{prop.reason}}</p><p><a href="{{url_for('preview',did=did)}}" target="_blank">Dokumentvorschau öffnen</a></p><form method="post"><input type="hidden" name="csrf" value="{{csrf}}"><label>Hauptkategorie<input name="primary" value="{{prop.primary_tag or ''}}" required></label><label>Weitere Tags (kommagetrennt)<input name="tags" value="{{(prop.additional_tags or [])|join(', ')}}"></label><label>Korrespondent<input name="correspondent" value="{{prop.correspondent_suggestion or prop.correspondent or ''}}"></label><label>Dokumentdatum YYYY-MM-DD (optional)<input name="date" value="{{prop.document_date or ''}}"></label><button type="submit">Korrigieren und freigeben</button></form></article>''',did=did,prop=prop,csrf=session['csrf'])

@app.route('/preview/<int:did>')
@require_login
def preview(did):
    if not job_for_doc(did):abort(404)
    response=requests.get(f'{PAPERLESS}/api/documents/{did}/preview/',headers={'Authorization':'Token '+token()},timeout=45)
    if response.status_code!=200:abort(502)
    return Response(response.content,content_type=response.headers.get('Content-Type','application/pdf'),headers={'X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; sandbox"})

if __name__=='__main__':
    from waitress import serve
    serve(app,host=os.environ.get('QUARANTINE_BIND','0.0.0.0'),port=int(os.environ.get('QUARANTINE_PORT','1889')),threads=4)
