# Hinweise für Claude

## Nutzungslimit schonen
- Workflows und Agents nur starten, wenn sie wirklich nötig sind, und klein halten (wenige Agents, enger Auftrag).
- Laufende Workflows und Agents beenden, sobald ihr Ergebnis nicht mehr gebraucht wird (z. B. wenn der Fehler schon gefunden oder der PR gemergt ist). Nichts im Hintergrund weiterlaufen lassen.
- Keine Audits oder Reviews neu starten, nur weil einer abgebrochen ist, außer der Nutzer will es.
- Auf CI und Releases warten, ohne Agents zu beschäftigen: höchstens eine kurze Prüfung zum erwarteten Zeitpunkt.

## Mergen und Veröffentlichen
- Eigene PRs ohne Nachfrage mergen, sobald der Build grün ist. Das Release startet dann von selbst (neue Datei unter `docs/releases/`), die App holt sich das Update über den Updater.
- Nur nachfragen, wenn die Nutzerin oder der Nutzer ausdrücklich sagt, dass noch gewartet werden soll.
