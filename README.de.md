# Stratovo · Android, Windows und Ubuntu auf dem Mac

[Website](https://pwnedg0blin.pages.dev/) · [Alle Projekte](https://pwnedg0blin.pages.dev/projekte) · [Unterstützen](https://pwnedg0blin.pages.dev/support)

Entwickelt von mir, **PwnedG0blin** · **1.0 Beta 7.7 · Mitternacht** · macOS 14+ · Apple Silicon.

Die Systemübersicht zeigt Windows, Android und Ubuntu als kompakte Einträge mit einer Hauptaktion. Einstellungen sind über beschriftete Buttons erreichbar. Android und Downloads sind übersichtlicher gegliedert. Mitternachtsfarben und optionales Liquid Glass bleiben erhalten.

Neu in Beta 7.7: Installationen lassen sich direkt in Stratovo entfernen. Bei Android wählst du das einzelne Profil. Nach Prüfung der angezeigten Pfade und Bestätigung per Häkchen wird **Löschen** aktiv. Die Gastdaten kommen in den macOS-Papierkorb und werden erst durch dessen Leeren endgültig gelöscht. Das entfernte System muss neu eingerichtet werden. Andere Installationen, gemeinsame Laufzeiten, eigene Sicherungen und Online-Konten bleiben erhalten.

SSH/SFTP einschließlich der Windows-Hostschlüsselkorrektur bleibt enthalten. Private Grafik- und Firmware-Experimente sind nicht Bestandteil dieser öffentlichen Beta.

Eine Oberfläche für Android ARM64, Windows mit 3D über Metal und Ubuntu ARM.
Android und Ubuntu laufen im Stratovo-Player. Windows Arm nutzt standardmäßig ein frei skalierbares direktes Metal-Grafikfenster; Text einfügen und Dateiaustausch bleiben im Hauptfenster erreichbar.
Gäste und Werkzeuge liegen auf deinem selbst gewählten Datenträger.

- Android 16 mit Google Play, optional Android 17; persistente Apps und Spielstände.
- Ein Windows-Bereich mit 3D auf deiner bisherigen Installation, ohne neue Testkopie.
- Ubuntu 26.04.1 LTS ARM64 mit geprüftem Download und eigener 64-GiB-Festplatte.
- Systemabhängige App-Sprache, 14 Sprachordner; technische Texte teilweise mit Ersatztexten.
- Dateiaustausch für Windows/Ubuntu über SSH/SFTP direkt in Stratovo; Android weiterhin über Datei-Senden und Abholen.
- GitHub-Updates mit Prüfungen vor der Installation.

[Download](https://github.com/PwnedG0blin/Stratovo/releases) · [Schritt-für-Schritt-Anleitung](LIES_MICH_ZUERST.md) ·
[Neu in Beta 7.7](docs/RELEASE_1.0_BETA7_7.md)

3D und Gastkompatibilität bleiben experimentell. Für den ersten Grafikbau werden
vollständiges Xcode mit Metal-Werkzeugen und mindestens 30 GiB benötigt. Die App
wird lokal signiert; Developer-ID-Signatur und Notarisierung sind noch nicht enthalten.

[GitHub Sponsors](https://github.com/sponsors/PwnedG0blin) · [Patreon](https://www.patreon.com/cw/PwnedG0blinApp) · [X](https://x.com/PwnedG0blin)

Copyright © 2026 PwnedG0blin und Mitwirkende · [Lizenz](LICENSE)

[Dateiaustausch zwischen Mac, Windows, Ubuntu und Android einrichten](docs/DATEIAUSTAUSCH.md).

Windows Arm startet standardmäßig im eigenen Cocoa-/Metal-Grafikfenster ohne VNC-Bildkopien. Die eingebettete Ansicht bleibt experimentell. Text einfügen und Dateiaustausch findest du in der Windows-Steuerung.

