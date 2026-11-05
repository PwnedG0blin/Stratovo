# Stratovo 1.0 Beta 7.8 · Build 1045

- Laufende Gastsitzungen zeigen nach dem Schließen des integrierten Playerfensters „Läuft im Hintergrund“. Mit „Fenster wieder öffnen“ kehrt der Player zurück.
- Android-Grafikeinstellungen lassen sich pro Profil manuell speichern und vor dem nächsten Start wiederherstellen.
- Die Diagnose bietet einen kompakten Android-Bericht zum Kopieren mit Renderer und Grafikfähigkeiten.
- Die Speicherbelegung des verbundenen Datenordners lässt sich nach seinen Unterordnern anzeigen.

## Verwendung

Die Grafikeinstellungen können bei gestopptem Android unter „Bild und Leistung“ gespeichert und wiederhergestellt werden. Diagnose und Speicherbelegung sind im Diagnosefenster erreichbar.

## Prüfung und bekannte Grenzen

Der öffentliche Testbuild hat die automatisierten macOS-Prüfungen und den App-Starttest bestanden. Die Release-Pipeline prüft und paketiert den zusammengeführten Stand erneut.

Das Wiederöffnen bezieht sich auf Stratovos integrierte Playerfenster. Die Speicherübersicht zeigt belegten Speicher nach Ordnern. Die Android-Kurzdiagnose sammelt ausgewählte Grafikangaben und bekannte Grafikfehlermeldungen.

Die fehlenden Kartenbilder in Master Duel bleiben offen. Spiele-Schnellstarts werden weiterhin ausschließlich privat getestet.

## Installation

Apple Silicon und macOS 14 oder neuer. DMG öffnen und Stratovo.app nach Programme ziehen. Die App ist lokal signiert. Developer-ID-Signierung und Notarisierung sind noch ausstehend.

Die SHA256SUMS-Datei enthält die Prüfsummen der App-ZIP und der DMG.
