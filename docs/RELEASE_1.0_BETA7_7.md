# Stratovo 1.0 Beta 7.7 · Aufgeräumte Oberfläche und Installationen verwalten

Stratovo bringt Android, Windows ARM64 und Ubuntu ARM in eine native Oberfläche für Apple-Silicon-Macs. Build **1044** dieser öffentlichen Beta bündelt die neue Systemübersicht, direkt beschriftete Einstellungsbuttons und die Verwaltung vorhandener Installationen.

## Neu

- **Meine Systeme:** kompakte Einträge für Windows, Android und Ubuntu mit einer Hauptaktion zum Starten oder Öffnen. Doppelte Startleisten entfallen.
- **Direkte Einstellungen:** Allgemein, Speicher, Downloads und Erweitert sind über beschriftete Buttons erreichbar. Aufklappbereiche verwenden ebenfalls sichtbare Buttons statt kleiner Pfeile.
- **Android:** Übersicht, Bild und Leistung, Netzwerk, Apps und Konto sowie Versionen sind getrennt anwählbar. Die Übersicht zeigt das gewählte Gerät und einen einzelnen Startknopf; wiederholte Erklärungen sind zusammengefasst.
- **Downloads:** kompakte Komponentenliste mit kurzem Installationsstatus. Android-Updates sind separat wählbar. Fortschritt, Protokolle und erforderliche Lizenzantworten erscheinen während der Einrichtung.
- **Installation entfernen:** Windows und Ubuntu lassen sich mit ihren lokalen Konten, Apps, Dateien und virtuellen Festplatten entfernen. Bei Android wird die konkrete Installation ausgewählt, einschließlich offizieller, Vorschau- und kopierter Profile.
- **Bestätigung per Häkchen:** Der Button **Löschen** bleibt bis zur Bestätigung ausgegraut. Die betroffenen Pfade und ein deutlicher Hinweis auf den Datenverlust werden vorher angezeigt.

## Was beim Löschen passiert

Die aufgeführten Gastdaten werden in einem zusammengehörigen Ordner mit einer Liste ihrer ursprünglichen Pfade in den macOS-Papierkorb verschoben. Erst das Leeren des Papierkorbs löscht diese Dateien endgültig. Das gewählte System muss danach neu eingerichtet werden. Bei Windows werden auch die von Stratovo gespeicherten Einrichtungs-Zugangsdaten im macOS-Schlüsselbund entfernt; die Ansicht weist darauf hin.

Andere Installationen, gemeinsame Laufzeiten, separat gesicherte Dateien und Online-Konten werden nicht entfernt. Android-Abbilder werden nur mitgenommen, wenn sie eindeutig zugeordnet sind und nicht von anderen Profilen verwendet werden; der gemeinsame Android-Austauschordner bleibt erhalten. Laufende Gastsysteme und Dateiübertragungen müssen vorher beendet werden. Bei einem Fehler versucht Stratovo bereits verschobene Ordner zurückzulegen und zeigt bei unvollständiger Wiederherstellung den Ablageort.

## Weiterhin Beta

Die öffentliche Grafik- und Player-Grundlage bleibt auf dem bisherigen öffentlichen Stand. Experimentelle private Android-Metal-/Transportänderungen und private Windows-Firmware gehören nicht zu dieser Veröffentlichung. Fehlende Kartenbilder in Master Duel, allgemeine Spieleleistung und Bluetooth-Unterstützung werden nicht als behoben angekündigt.

Der SSH/SFTP-Dateiaustausch aus Beta 7.4 einschließlich der Windows-Hostschlüsselkorrektur ist weiterhin enthalten. Automatisierte Prüfungen laufen vor der Veröffentlichung; insbesondere werden die Löschplanung, Isolation anderer Installationen, Fehler-Rücknahme und der native Papierkorb mit Testdaten geprüft. Tests ersetzen keine vollständige Erprobung auf jedem echten Gast.

macOS 14+ · Apple Silicon · kostenlos und Open Source. Die App ist ad hoc signiert; Developer-ID-Signatur und Notarisierung sind weiterhin nicht enthalten.

## English

Beta 7.7 adds a compact system library, labeled settings buttons, a clearer Android workspace and shorter download setup. Windows, Ubuntu and individual Android installations can now be removed from the interface. The Delete button stays disabled until the acknowledgment checkbox is checked. Exact affected paths and a data-loss warning are shown before removal.

Selected guest data is moved together to the native macOS Trash; emptying the Trash deletes it permanently. The removed system requires fresh setup. Shared runtimes, other installations, separate backups and online accounts are retained. Android images are removed only when ownership and references can be safely established. Scoped SSH setup data is removed with Windows/Ubuntu, and saved Stratovo Windows setup credentials are cleared from Keychain.

The public graphics/player foundation is unchanged. Private Android Metal/transport experiments and private Windows firmware are not included. This release does not claim fixes for Master Duel card images, general game performance or Bluetooth. Existing SSH/SFTP setup and host-key repair remain available. macOS 14+ on Apple Silicon; free and open source; ad-hoc signed, not notarized.
