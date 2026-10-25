using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

[DataContract] public sealed class ExchangeConfig {
    [DataMember] public string endpoint;
    [DataMember] public string publicKey;
    [DataMember] public string mode;
}
[DataContract] public sealed class Update {
    [DataMember] public string stage;
    [DataMember] public string message;
    [DataMember] public string user;
    [DataMember] public string key;
}
public static class StratovoExchange {
    static string step = "Start";
    static readonly string DiagnosticPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Stratovo", "Dateiaustausch-Diagnose.log");
    static void Log(string message) {
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(DiagnosticPath));
            File.AppendAllText(DiagnosticPath, DateTime.Now.ToString("s") + " " + message + Environment.NewLine, new UTF8Encoding(false));
        } catch { } // A diagnostic write must never prevent setup or hide the original error.
    }
    static void Step(string value) { step = value; Log(value); }
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    static readonly SecurityIdentifier SystemSid = new SecurityIdentifier("S-1-5-18");
    static readonly SecurityIdentifier AdminSid = new SecurityIdentifier("S-1-5-32-544");
    public static void Validate(ExchangeConfig config) {
        Uri endpoint;
        if (config == null || !Uri.TryCreate(config.endpoint, UriKind.Absolute, out endpoint) ||
            endpoint.Scheme != "http" || endpoint.Host != "10.0.2.2" || endpoint.Port < 1 ||
            endpoint.UserInfo != "" || endpoint.Query != "" || endpoint.Fragment != "" ||
            !Regex.IsMatch(endpoint.AbsolutePath, "^/[a-f0-9]{32}$") ||
            (config.mode != "setup" && config.mode != "capture")) throw new Exception("Ungueltige Einrichtungsdaten.");
        if (config.mode == "setup") {
            if (config.publicKey == null || !Regex.IsMatch(config.publicKey, "^ssh-ed25519 [A-Za-z0-9+/=]+ Stratovo-Dateiaustausch$"))
                throw new Exception("Ungueltiger SSH-Schluessel.");
            byte[] key = Convert.FromBase64String(config.publicKey.Split(' ')[1]);
            byte[] prefix = {0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32};
            if (key.Length != 51) throw new Exception("Ungueltiger SSH-Schluessel.");
            for (int i=0;i<prefix.Length;i++) if (key[i] != prefix[i]) throw new Exception("Ungueltiger SSH-Schluessel.");
        }
    }
    static void Post(ExchangeConfig config, string path, byte[] body, string type) {
        var request = (HttpWebRequest)WebRequest.Create(config.endpoint + path);
        request.Proxy = null; request.AllowAutoRedirect = false; request.Method = "POST";
        // The small loopback server reads a complete body before replying; do not request an interim 100 response.
        request.ServicePoint.Expect100Continue = false; request.KeepAlive = false;
        request.Timeout = 8000; request.ReadWriteTimeout = 8000; request.ContentType = type; request.ContentLength = body.Length;
        try {
            using (var stream = request.GetRequestStream()) stream.Write(body, 0, body.Length);
            using (var response = (HttpWebResponse)request.GetResponse()) {
                if (response.StatusCode != HttpStatusCode.OK) throw new Exception("Stratovo-Verbindung nicht erreichbar.");
            }
        } catch (WebException error) {
            Log("Mac-Verbindung: " + error.Status); // Never record the capability URL or request body.
            throw new Exception("Rueckmeldung an Stratovo auf dem Mac fehlgeschlagen (" + error.Status + "). Dateiaustausch am Mac erneut starten.", error);
        }
    }
    static void Report(ExchangeConfig config, string stage, string message, string user = null, string key = null) {
        using (var stream = new MemoryStream()) {
            new DataContractJsonSerializer(typeof(Update)).WriteObject(stream, new Update {stage=stage, message=message, user=user, key=key});
            Post(config, "/status", stream.ToArray(), "application/json; charset=utf-8");
        }
    }
    static string Tool(string name) { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", name); }
    static void Run(string name, string args, bool allowRestart = false, int allowedExit = 0) {
        Log("Windows-Werkzeug: " + name);
        // All commands are fixed Windows tools, with no shell, downloaded code or script-policy changes.
        using (var process = Process.Start(new ProcessStartInfo(Tool(name), args) {UseShellExecute=false, CreateNoWindow=false})) {
            if (!process.WaitForExit(1200000)) throw new Exception(name + " hat zu lange gebraucht. Windows neu starten und Einrichtung wiederholen.");
            Log(name + " Exitcode: " + process.ExitCode);
            if (process.ExitCode == 3010 && allowRestart) throw new Exception("Windows neu starten und Dateiaustausch starten erneut waehlen.");
            if (process.ExitCode != 0 && process.ExitCode != allowedExit) throw new Exception(name + " meldet Fehler " + process.ExitCode + ".");
        }
    }
    static void RejectLink(string path) {
        if ((File.Exists(path) || Directory.Exists(path)) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new Exception("SSH-Pfad darf keine Verknuepfung sein: " + path);
    }
    static void SecureHostKeys(string folder) {
        RejectLink(folder);
        foreach (string algorithm in new [] {"rsa", "ecdsa", "ed25519"}) {
            string path = Path.Combine(folder, "ssh_host_" + algorithm + "_key");
            if (!File.Exists(path)) continue;
            RejectLink(path);
            // ssh-keygen -A runs elevated as the user. Explicit user ownership/access can
            // make sshd reject these keys when it runs as SYSTEM (Windows error 1067).
            var acl = new FileSecurity();
            // Administrators is an accepted OpenSSH owner and can be assigned with normal
            // elevation; assigning SYSTEM would additionally require SeRestorePrivilege.
            acl.SetOwner(AdminSid); acl.SetAccessRuleProtection(true, false);
            foreach (var principal in new [] {SystemSid, AdminSid})
                acl.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl, AccessControlType.Allow));
            File.SetAccessControl(path, acl);
            Log("Hostschluesselrechte eingerichtet: " + Path.GetFileName(path));
        }
    }
    static void Install(ExchangeConfig config, string sidText, bool administrator) {
        var identity = WindowsIdentity.GetCurrent();
        if (!new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator)) throw new Exception("Administratorfreigabe fehlt.");
        var sid = new SecurityIdentifier(sidText);
        if (!sidText.StartsWith("S-1-5-21-", StringComparison.Ordinal)) throw new Exception("Ungueltiges Benutzerkonto.");
        var account = (NTAccount)sid.Translate(typeof(NTAccount));
        string user = account.Value.Substring(account.Value.LastIndexOf('\\')+1);
        string profile;
        using (var registry = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + sid.Value)) {
            profile = registry == null ? null : registry.GetValue("ProfileImagePath") as string;
        }
        if (profile == null || !Directory.Exists(profile)) throw new Exception("Windows-Benutzerordner nicht erreichbar.");
        Step("OpenSSH-Installation");
        Report(config, "install", "Windows installiert bei Bedarf den OpenSSH-Dienst.");
        if (!File.Exists(Tool(@"OpenSSH\sshd.exe"))) Run("dism.exe", "/Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart", true);
        Step("SSH-Konfiguration");
        Report(config, "configure", "SSH-Schluessel und Verbindung werden eingerichtet.");
        Run(@"OpenSSH\ssh-keygen.exe", "-A");
        Step("SSH-Hostschluesselrechte");
        SecureHostKeys(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ssh"));
        Step("SSH-Zugang einrichten");
        string folder = administrator ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ssh") : Path.Combine(profile, ".ssh");
        RejectLink(profile); RejectLink(folder);
        Directory.CreateDirectory(folder);
        string path = Path.Combine(folder, administrator ? "administrators_authorized_keys" : "authorized_keys");
        RejectLink(path);
        string key = "restrict,command=\"internal-sftp\" " + config.publicKey;
        string[] lines = File.Exists(path) ? File.ReadAllLines(path) : new string[0];
        if (Array.IndexOf(lines, key) < 0) File.AppendAllText(path, Environment.NewLine + key + Environment.NewLine, new UTF8Encoding(false));
        var owner = administrator ? AdminSid : sid;
        var acl = new FileSecurity(); acl.SetAccessRuleProtection(true, false); acl.SetOwner(owner);
        acl.AddAccessRule(new FileSystemAccessRule(owner, FileSystemRights.FullControl, AccessControlType.Allow));
        acl.AddAccessRule(new FileSystemAccessRule(SystemSid, FileSystemRights.FullControl, AccessControlType.Allow));
        File.SetAccessControl(path, acl);
        if (!administrator) {
            var directoryAcl = new DirectorySecurity(); directoryAcl.SetAccessRuleProtection(true, false); directoryAcl.SetOwner(sid);
            foreach (var principal in new [] {sid, SystemSid}) directoryAcl.AddAccessRule(new FileSystemAccessRule(principal, FileSystemRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(folder, directoryAcl);
        }
        // Update only our own firewall rule; restrict it to the QEMU host gateway.
        Run("netsh.exe", "advfirewall firewall delete rule name=\"Stratovo-SSH-Exchange\"", false, 1);
        Run("netsh.exe", "advfirewall firewall add rule name=\"Stratovo-SSH-Exchange\" dir=in action=allow protocol=TCP localport=22 remoteip=10.0.2.2 profile=any");
        Run("sc.exe", "config sshd start= auto");
        Step("Windows-Dienst sshd starten");
        try {
            using (var service = new ServiceController("sshd")) {
                service.Refresh();
                Log("sshd vor Start: " + service.Status);
                if (service.Status != ServiceControllerStatus.Running) {
                    if (service.Status != ServiceControllerStatus.StartPending) service.Start();
                    var deadline = DateTime.UtcNow.AddSeconds(30);
                    do {
                        service.Refresh();
                        if (service.Status == ServiceControllerStatus.Running) break;
                        if (service.Status == ServiceControllerStatus.Stopped)
                            throw new Exception("Der Windows-Dienst sshd wurde beim Start wieder beendet.");
                        System.Threading.Thread.Sleep(250);
                    } while (DateTime.UtcNow < deadline);
                    if (service.Status != ServiceControllerStatus.Running)
                        throw new Exception("Der Windows-Dienst sshd hat innerhalb von 30 Sekunden keinen laufenden Zustand erreicht.");
                }
                Log("sshd nach Start: " + service.Status);
            }
        } catch (Exception error) {
            Log(error.ToString());
            try {
                using (var query = Process.Start(new ProcessStartInfo(Tool("sc.exe"), "queryex sshd") {
                    UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true
                })) {
                    if (query.WaitForExit(5000)) Log(query.StandardOutput.ReadToEnd());
                }
            } catch { }
            throw new Exception("Windows kann den SSH-Dienst nicht starten. Bitte 'Diagnose oeffnen' waehlen. " + error.Message, error);
        }
        Step("Abschluss an Mac melden");
        string hostKey = File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "ssh", "ssh_host_ed25519_key.pub")).Trim();
        Report(config, "ready", "Einrichtung abgeschlossen.", user, hostKey);
    }
    static void Capture(ExchangeConfig config) {
        SetProcessDPIAware();
        var area = SystemInformation.VirtualScreen;
        using (var bitmap = new Bitmap(area.Width, area.Height)) {
            using (var graphics = Graphics.FromImage(bitmap)) graphics.CopyFromScreen(area.Left, area.Top, 0, 0, area.Size);
            using (var stream = new MemoryStream()) { bitmap.Save(stream, System.Drawing.Imaging.ImageFormat.Png); Post(config, "/image", stream.ToArray(), "image/png"); }
        }
    }
    static int SelfTest() {
        string baseURL = "http://10.0.2.2:51234/" + new string('a',32);
        Validate(new ExchangeConfig {endpoint=baseURL,mode="capture"});
        foreach (string endpoint in new [] {"https://example.com/a", baseURL+"?other=1", "http://127.0.0.1:123/a", baseURL+"/setup"}) {
            try { Validate(new ExchangeConfig {endpoint=endpoint,mode="capture"}); return 2; } catch { }
        }
        byte[] key = new byte[51]; byte[] prefix={0,0,0,11,115,115,104,45,101,100,50,53,53,49,57,0,0,0,32}; Array.Copy(prefix,key,prefix.Length);
        Validate(new ExchangeConfig {endpoint=baseURL,mode="setup",publicKey="ssh-ed25519 "+Convert.ToBase64String(key)+" Stratovo-Dateiaustausch"});
        try {Validate(new ExchangeConfig {endpoint=baseURL,mode="setup",publicKey="ssh-ed25519 AAAA Stratovo-Dateiaustausch"});return 3;}catch{}
        // Exercise the real .NET HTTP client against the complete-body protocol used by the Mac.
        var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try {
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var receive = Task.Run(() => {
                using (var client = listener.AcceptTcpClient()) {
                    client.ReceiveTimeout=3000; client.SendTimeout=3000;
                    using (var stream = client.GetStream()) {
                        var header = new StringBuilder();
                        while (!header.ToString().EndsWith("\r\n\r\n", StringComparison.Ordinal)) {
                            int value=stream.ReadByte();
                            if (value < 0 || header.Length > 8192) throw new Exception("Invalid test request.");
                            header.Append((char)value);
                        }
                        if (header.ToString().IndexOf("Expect:", StringComparison.OrdinalIgnoreCase) >= 0)
                            throw new Exception("Unexpected HTTP interim-response requirement.");
                        if (stream.ReadByte() != 123 || stream.ReadByte() != 125) throw new Exception("Missing status body.");
                        byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
                        stream.Write(response,0,response.Length);
                    }
                }
            });
            Post(new ExchangeConfig {endpoint="http://127.0.0.1:"+port}, "/status", Encoding.ASCII.GetBytes("{}"), "application/json");
            if (!receive.Wait(5000)) return 4;
        } finally { listener.Stop(); }
        // Regression: repair user-created private keys, preserve identity bytes and public keys,
        // and remain safe to run again on an already-configured installation.
        string root = Path.Combine(Path.GetTempPath(), "Stratovo-Hostkey-Test-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            foreach (string algorithm in new [] {"rsa", "ecdsa", "ed25519"})
                File.WriteAllText(Path.Combine(root,"ssh_host_"+algorithm+"_key"), "existing identity " + algorithm);
            string publicPath = Path.Combine(root,"ssh_host_ed25519_key.pub");
            File.WriteAllText(publicPath,"public sentinel");
            string publicAcl = File.GetAccessControl(publicPath).GetSecurityDescriptorSddlForm(AccessControlSections.All);
            SecureHostKeys(root); SecureHostKeys(root);
            foreach (string algorithm in new [] {"rsa", "ecdsa", "ed25519"}) {
                string path = Path.Combine(root,"ssh_host_"+algorithm+"_key");
                var acl = File.GetAccessControl(path);
                if (File.ReadAllText(path) != "existing identity " + algorithm ||
                    !acl.AreAccessRulesProtected || !acl.GetOwner(typeof(SecurityIdentifier)).Equals(AdminSid)) return 5;
                var rules = acl.GetAccessRules(true,true,typeof(SecurityIdentifier));
                if (rules.Count != 2) return 6;
                foreach (FileSystemAccessRule rule in rules)
                    if ((!rule.IdentityReference.Equals(SystemSid) && !rule.IdentityReference.Equals(AdminSid)) ||
                        rule.AccessControlType != AccessControlType.Allow || rule.FileSystemRights != FileSystemRights.FullControl) return 7;
            }
            if (File.ReadAllText(publicPath) != "public sentinel" ||
                File.GetAccessControl(publicPath).GetSecurityDescriptorSddlForm(AccessControlSections.All) != publicAcl) return 8;
        } finally { Directory.Delete(root,true); }
        return 0;
    }
    [STAThread] public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--self-test") {
            try { return SelfTest(); }
            catch (Exception error) {
                File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"self-test-error.txt"),error.ToString());
                return 1;
            }
        }
        SetProcessDPIAware();
        Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
        ExchangeConfig config = null;
        try {
            using (var stream = File.OpenRead(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "exchange.json")))
                config = (ExchangeConfig)new DataContractJsonSerializer(typeof(ExchangeConfig)).ReadObject(stream);
            Validate(config);
            bool elevated = args.Length == 3 && args[0] == "--install" && (args[2] == "admin" || args[2] == "user");
            bool capture = config.mode == "capture";
            if (args.Length != 0 && !elevated) throw new Exception("Ungueltiger Aufruf.");
            var form = new Form {Text="Stratovo · Dateiaustausch", Width=570, Height=285, StartPosition=FormStartPosition.CenterScreen, MaximizeBox=false};
            var label = new Label {Left=24, Top=22, Width=510, Height=135,
                Text=capture ? "Vergleichsbild aufnehmen\r\n\r\nNach dem Start bleiben 5 Sekunden, um zum betroffenen Fenster zu wechseln. Das Bild wird an Stratovo auf deinem Mac gesendet." :
                "SSH-Dateiaustausch mit deinem Mac\r\n\r\nStratovo installiert den Windows-OpenSSH-Dienst, hinterlegt seinen Schluessel und erlaubt die Verbindung vom VM-Host. Bitte die Windows-Administratorabfrage bestaetigen."};
            var button = new Button {Left=24, Top=177, Width=220, Height=36, Text=capture ? "Bild aufnehmen" : "Dateiaustausch einrichten"};
            var diagnostic = new Button {Left=260, Top=177, Width=245, Height=36, Text="Diagnose oeffnen"};
            diagnostic.Click += (sender,e) => {
                Log("Diagnose geoeffnet.");
                try { Process.Start(new ProcessStartInfo(Tool("notepad.exe"), "\"" + DiagnosticPath + "\"") {UseShellExecute=true}); }
                catch (Exception error) { MessageBox.Show(error.Message, "Stratovo"); }
            };
            form.Controls.Add(label); form.Controls.Add(button); form.Controls.Add(diagnostic);
            bool busy = false;
            form.FormClosing += (sender,e) => {if(busy)e.Cancel=true;};
            Func<Task> work = async () => {
                button.Enabled=false; busy=true;
                string failureMessage = null;
                try {
                    Step("Verbindung zum Mac pruefen");
                    await Task.Run(() => Report(config,"configure",capture ? "Vergleichsbild wird aufgenommen." : "Einrichtungsprogramm gestartet."));
                    if (capture) {
                        form.Hide(); await Task.Delay(5000); await Task.Run(() => Capture(config));
                        busy=false; form.Close(); return;
                    }
                    if (elevated) {
                        label.Text="OpenSSH wird eingerichtet. Das kann einige Minuten dauern.";
                        await Task.Run(() => Install(config,args[1],args[2]=="admin"));
                    } else {
                        var identity = WindowsIdentity.GetCurrent(); bool admin=false;
                        foreach (var group in identity.Groups) if (group.Value == AdminSid.Value) admin=true;
                        Step("Windows-Administratorfreigabe");
                        await Task.Run(() => Report(config,"confirm","Bitte die Windows-Administratorabfrage bestaetigen."));
                        using (var process=Process.Start(new ProcessStartInfo(Application.ExecutablePath,
                            "--install " + identity.User.Value + (admin ? " admin" : " user")) {UseShellExecute=true, Verb="runas"})) {
                            form.Hide(); await Task.Run(() => process.WaitForExit());
                            if (process.ExitCode != 0) throw new Exception("Einrichtung wurde nicht abgeschlossen.");
                        }
                    }
                    busy=false; form.Close();
                } catch (Exception error) {
                    string message = "Schritt: " + step + "\r\n" + error.Message;
                    failureMessage = message;
                    Log(message);
                    label.Text="Einrichtung nicht abgeschlossen:\r\n\r\n"+message;
                    button.Text="Erneut versuchen"; form.Show();
                }
                if (failureMessage != null) {
                    // Await outside catch for the framework's C# 5 compiler. Preserve the original failure.
                    try {await Task.Run(() => Report(config,"error",failureMessage));} catch { }
                    button.Enabled=true; busy=false;
                }
            };
            button.Click += async (sender,e) => await work();
            if (elevated) form.Shown += async (sender,e) => await work();
            Application.Run(form); return 0;
        } catch (Exception error) { MessageBox.Show(error.Message,"Stratovo",MessageBoxButtons.OK,MessageBoxIcon.Error); return 1; }
    }
}
