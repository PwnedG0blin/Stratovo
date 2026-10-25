import Foundation
import StratovoCore

enum GuestBootstrapScripts {
    static func launch(kind: ExchangeGuest, baseURL: String) throws -> String {
        guard let url = URL(string: baseURL), url.scheme == "http", url.host == "10.0.2.2",
              url.port != nil, url.path.range(of: #"^/[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
            throw GuestError.invalidResources
        }
        guard kind == .ubuntu else { throw GuestError.invalidResources }
        return "python3 -c 'import urllib.request;exec(urllib.request.urlopen(\"\(baseURL)/setup\").read())'"
    }

    static func script(kind: ExchangeGuest, publicKey: String, baseURL: String) throws -> String {
        _ = try launch(kind: kind, baseURL: baseURL)
        let fields = publicKey.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count == 3, fields[0] == "ssh-ed25519", fields[2] == "Stratovo-Dateiaustausch",
              let data = Data(base64Encoded: String(fields[1])), data.count == 51 else { throw GuestError.invalidResources }
        let key = fields.joined(separator: " ")
        return ubuntu(publicKey: key, baseURL: baseURL)
    }

    static func ubuntu(publicKey: String, baseURL: String) -> String {
        let admin = #"""
        import os, sys, json, pathlib, subprocess, urllib.request, shutil, stat
        endpoint = 'BASEURL/status'
        def report(stage, message, user='', key=''):
            body=json.dumps(dict(stage=stage,message=message,user=user,key=key)).encode()
            request=urllib.request.Request(endpoint,data=body,headers={'Content-Type':'application/json'},method='POST')
            urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=8).close()
        def run(args, timeout=600):
            result=subprocess.run(args,capture_output=True,text=True,timeout=timeout,env=dict(os.environ,DEBIAN_FRONTEND='noninteractive',LC_ALL='C'))
            if result.returncode: raise RuntimeError((result.stderr or result.stdout or 'Einrichtung fehlgeschlagen.')[-1500:])
        try:
            if not pathlib.Path('/usr/sbin/sshd').is_file():
                report('install','Ubuntu installiert den SSH-Dienst. Das kann einige Minuten dauern.')
                run(['/usr/bin/apt-get','update'])
                run(['/usr/bin/apt-get','install','-y','--no-install-recommends','openssh-server'])
            report('configure','Die geschuetzte Verbindung wird eingerichtet.')
            directory=pathlib.Path(target['home'])/'.ssh'
            keys=directory/'authorized_keys'
            if directory.is_symlink() or keys.is_symlink(): raise RuntimeError('Der SSH-Schluesselordner ist eine Verknuepfung.')
            directory.mkdir(mode=0o700,exist_ok=True)
            directory.chmod(0o700); os.chown(directory,target['uid'],target['gid'])
            line='restrict,command="internal-sftp" PUBLICKEY'
            existing=keys.read_text() if keys.exists() else ''
            if line not in existing.splitlines():
                with keys.open('a') as output: output.write('\n'+line+'\n')
            keys.chmod(0o600); os.chown(keys,target['uid'],target['gid'])
            run(['/usr/bin/ssh-keygen','-A'])
            if shutil.which('ufw'): run([shutil.which('ufw'),'allow','from','10.0.2.2','to','any','port','22','proto','tcp'])
            run(['/usr/bin/systemctl','enable','--now','ssh'])
            key=pathlib.Path('/etc/ssh/ssh_host_ed25519_key.pub').read_text().strip()
            report('ready','Verbindung wird geprueft.',target['user'],key)
        except Exception as error:
            try: report('error',str(error)[:1500])
            except Exception: pass
            sys.exit(1)
        """#.replacingOccurrences(of: "BASEURL", with: baseURL).replacingOccurrences(of: "PUBLICKEY", with: publicKey)
        let encoded = Data(admin.utf8).base64EncodedString()
        return #"""
        import os, sys, pwd, json, base64, subprocess, urllib.request
        def report(stage,message):
            body=json.dumps(dict(stage=stage,message=message)).encode()
            request=urllib.request.Request('BASEURL/status',data=body,headers={'Content-Type':'application/json'},method='POST')
            urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request,timeout=8).close()
        try:
            account=pwd.getpwuid(os.getuid())
            target=dict(user=account.pw_name,home=account.pw_dir,uid=account.pw_uid,gid=account.pw_gid)
            body='target='+repr(target)+'\n'+base64.b64decode('ADMINBODY').decode()
            if os.geteuid()==0: exec(body)
            else:
                report('confirm','Bitte die Administratorabfrage in Ubuntu bestaetigen.')
                result=subprocess.run(['pkexec','/usr/bin/python3','-c',body])
                if result.returncode: raise RuntimeError('Ubuntu-Einrichtung wurde abgebrochen oder ist fehlgeschlagen.')
        except Exception as error:
            try: report('error',str(error)[:1500])
            except Exception: pass
        """#.replacingOccurrences(of: "BASEURL", with: baseURL).replacingOccurrences(of: "ADMINBODY", with: encoded)
    }
}
