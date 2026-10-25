# Stratovo 1.0 Beta 7.4 · SSH-Dateiaustausch

Dieses öffentliche Update betrifft ausschließlich den SSH/SFTP-Dateiaustausch und dessen Einrichtung. Die neuen Android-Player, deren Drehfunktion und weitere private Grafikänderungen sind nicht enthalten.

- Windows und Ubuntu: Dateiaustausch in Stratovo öffnen, das System starten und **Dateiaustausch starten** wählen. Danach lassen sich Ordner durchsuchen und ausgewählte Dateien senden oder empfangen.
- Windows verwendet einen sichtbaren Einrichtungshelfer auf der virtuellen CD **STRATOVO**. **Dateiaustausch einrichten** wählen und die Windows-Administratorabfrage bestätigen. Der Benutzername wird automatisch ermittelt.
- Behoben: Der Windows-SSH-Dienst konnte trotz installierter OpenSSH-Komponente sofort wieder abbrechen. Die Einrichtung korrigiert jetzt Eigentümer und Berechtigungen vorhandener privater SSH-Hostschlüssel vor dem Dienststart. Die manuelle Terminal-Korrektur entfällt bei diesem Fehler.
- Die Verbindung nutzt Schlüsselanmeldung und einen lokalen Zugang zur VM. Eine macOS-SMB-Freigabe ist dafür nicht erforderlich. Einrichtungsfehler lassen sich im Windows-Helfer über **Diagnose oeffnen** anzeigen.
- Android behält den bisherigen Datei-Senden-/Abholen-Weg. Es werden keine privaten Android-Leistungs- oder Kartenbildkorrekturen als behoben angekündigt.

Nach dem App-Update Windows vollständig herunterfahren und neu starten, damit das Einrichtungs-CD-Laufwerk vorhanden ist. Falls der Helfer nicht automatisch erscheint: in Windows **Dieser PC → STRATOVO → Stratovo.exe** öffnen. Bei bereits gekoppelter Verbindung kann **Verbindung erneut einrichten** die korrigierte Einrichtung ausführen.

Die manuelle Schlüsselkorrektur wurde vom Tester als wirksam bestätigt; automatisierte Prüfungen decken die Reparatur, unveränderte Schlüsseldateien und wiederholte Ausführung ab. Eine abgeschlossene Dateiübertragung in beide Richtungen muss weiterhin am echten Gast geprüft werden. Dies bleibt eine Beta.

## English

This public update is limited to SSH/SFTP file exchange and setup. Windows and Ubuntu can browse guest folders and transfer selected files from Stratovo. Windows uses a visible setup helper on the STRATOVO virtual CD and automatically repairs invalid private SSH host-key ownership/permissions before starting sshd. Confirm the guest administrator prompt; no macOS SMB share is required.

Fully shut down and restart Windows after updating the app. If setup does not appear, open **This PC → STRATOVO → Stratovo.exe** and choose file exchange setup. For an existing pairing, use **Set up connection again**. Android retains its existing transfer and player behavior. Private Android graphics/rotation changes are not included. Guest end-to-end transfer verification remains necessary; this is a beta.
