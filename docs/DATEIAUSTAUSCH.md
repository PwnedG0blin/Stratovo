# Dateiaustausch

## Windows und Ubuntu

1. Das gewünschte System vollständig starten und dessen Desktop öffnen. In Windows muss das Netzwerk eingeschaltet sein.
2. In Stratovo **Dateiaustausch** öffnen und beim gewünschten System **Dateiaustausch starten** wählen.
3. In Windows im sichtbaren Stratovo-Helfer **Dateiaustausch einrichten** wählen. Die Administratorabfrage im Gastsystem bestätigen. Ubuntu zeigt seine eigene Administratorabfrage.
4. Nach erfolgreicher Einrichtung erscheinen die Dateien des Benutzerordners in Stratovo. Ordner öffnen, **Dateien senden** oder Dateien markieren und **Ausgewählte Dateien empfangen** wählen.

Die Verbindung wird über SSH/SFTP eingerichtet. Eine macOS-Dateifreigabe ist nicht nötig. Der Benutzername wird ermittelt; spätere Verbindungen verwenden die gekoppelte Schlüsselanmeldung.

Nach dem Update Windows einmal vollständig herunterfahren und neu starten. Falls der Helfer nicht erscheint: **Dieser PC → STRATOVO → Stratovo.exe** öffnen. Im Helfer zeigt **Diagnose oeffnen** den Einrichtungsablauf. Eine bereits verbundene Einrichtung kann über **Verbindung erneut einrichten** repariert werden. Der SSH-Hostschlüsselfehler mit sofort abbrechendem Dienst wird dabei automatisch korrigiert.

## Android

Android starten und warten, bis der Start abgeschlossen ist. **Datei zu Android senden** kopiert die gewählte Datei nach **Downloads → Stratovo-Austausch**, in einen neuen Unterordner. Zum Abholen gewünschte Dateien in Android nach **Downloads → Stratovo-Austausch** kopieren und in Stratovo **Android-Dateien abholen** wählen. Der Finder öffnet den neuen Importordner. Dieser bestehende Weg nutzt ADB.

## English

Start the guest desktop, open **File exchange**, and choose **Start file exchange** under Windows or Ubuntu. In the Windows helper choose file exchange setup, then confirm the guest administrator prompt. Browse folders and use the send/receive buttons after setup. No macOS SMB share is needed.

After updating Stratovo, fully shut down and restart Windows. If necessary, open **This PC → STRATOVO → Stratovo.exe**. The helper can display setup diagnostics and repairs invalid private SSH host-key permissions before starting the service. For Android, use the existing send/import actions and **Downloads → Stratovo-Austausch**.
