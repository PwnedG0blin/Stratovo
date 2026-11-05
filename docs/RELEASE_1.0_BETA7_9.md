# Stratovo 1.0 Beta 7.9 · Build 1046

Der Update-Helfer läuft als einmaliger, unabhängiger Prozess. Stratovo wartet vor dem Beenden auf die Bestätigung, dass die neue App vollständig vorbereitet und geprüft wurde. Die installierte Buildnummer wird nach dem Austausch erneut geprüft und Stratovo als neue Instanz geöffnet.

Fehler im Helfer werden mit der jeweiligen Installationsphase protokolliert. Falls der Start der neuen App fehlschlägt, stellt der Helfer die vorherige App wieder her.

## Installation dieser Reparatur

Beende Stratovo und installiere diese Version einmal über die DMG oder App-ZIP in Programme. Damit erhält die bisherige App den reparierten Update-Helfer.

## Prüfung

Die Tests prüfen den erfolgreichen Austausch, die Wiederherstellung nach einem fehlgeschlagenen Neustart, ungültige Pakete und App-Verknüpfungen sowie die unabhängige Ausführung des Helfers unter macOS. Der vollständige macOS-Build einschließlich App-Starttest muss vor der automatischen Veröffentlichung erfolgreich sein.

Apple Silicon und macOS 14 oder neuer. Die App ist lokal signiert. Developer-ID-Signierung und Notarisierung stehen aus.
