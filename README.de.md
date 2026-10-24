# Stratovo · Android, Windows und Ubuntu auf dem Mac

[Website](https://pwnedg0blin.pages.dev/) · [Alle Projekte](https://pwnedg0blin.pages.dev/projekte) · [Unterstützen](https://pwnedg0blin.pages.dev/support)

Entwickelt von **PwnedG0blin** · **1.0 Beta 7.3 · Mitternacht** · macOS 14+ · Apple Silicon.

Die neue bebilderte Übersicht zeigt Windows, Android und Ubuntu mit einer dauerhaft
erreichbaren Startleiste. Dunkelblau, Türkis und Violett sowie optionales natives
Liquid Glass ab macOS 26 prägen das neue Design. Die Darstellung ist einstellbar;
Bedienungshilfen haben Vorrang. Dies bleibt ausdrücklich eine fortlaufende Beta.

Eine Oberfläche für Android ARM64, Windows mit 3D über Metal und Ubuntu ARM.
Android und Ubuntu laufen im Stratovo-Player. Windows Arm nutzt standardmäßig ein frei skalierbares direktes Metal-Grafikfenster; Text einfügen und Dateiaustausch bleiben im Hauptfenster erreichbar.
Gäste und Werkzeuge liegen auf deinem selbst gewählten Datenträger.

- Android 16 mit Google Play, optional Android 17; persistente Apps und Spielstände.
- Ein Windows-Bereich mit 3D auf deiner bisherigen Installation, ohne neue Testkopie.
- Ubuntu 26.04.1 LTS ARM64 mit geprüftem Download und eigener 64-GiB-Festplatte.
- Systemabhängige App-Sprache, 14 Sprachordner; technische Texte teilweise mit Ersatztexten.
- Austauschordner im gewählten Datenordner: Windows/Ubuntu über SMB, Android über Datei-Senden und Abholen.
- GitHub-Updates mit Prüfungen vor der Installation.

[Download](https://github.com/PwnedG0blin/Stratovo/releases) · [Schritt-für-Schritt-Anleitung](LIES_MICH_ZUERST.md) ·
[Neu in Beta 7.3](docs/RELEASE_1.0_BETA7_3.md)

3D und Gastkompatibilität bleiben experimentell. Für den ersten Grafikbau werden
vollständiges Xcode mit Metal-Werkzeugen und mindestens 30 GiB benötigt. Die App
wird lokal signiert; Developer-ID-Signatur und Notarisierung sind noch nicht enthalten.

[GitHub Sponsors](https://github.com/sponsors/PwnedG0blin) · [Patreon](https://www.patreon.com/cw/PwnedG0blinApp) · [X](https://x.com/PwnedG0blin)

Copyright © 2026 PwnedG0blin und Mitwirkende · [Lizenz](LICENSE)

[Dateiaustausch zwischen Mac, Windows, Ubuntu und Android einrichten](docs/DATEIAUSTAUSCH.md).

Windows Arm startet standardmäßig im eigenen Cocoa-/Metal-Grafikfenster ohne VNC-Bildkopien. Die eingebettete Ansicht bleibt experimentell. Text einfügen und Dateiaustausch findest du in der Windows-Steuerung.
