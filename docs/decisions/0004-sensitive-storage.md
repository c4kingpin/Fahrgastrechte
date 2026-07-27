# ADR 0004: Geschützter Dokument- und Feldspeicher

- Status: akzeptiert
- Datum: 2026-07-27
- Betrifft: C00, C01, C03, C05, C07

## Kontext

Tickets, Rechnungen, erzeugte Anträge, IBAN und BIC sind sensible Daten.
Dateien müssen Neustarts überstehen, dürfen aber weder über statische Pfade
noch durch Kenntnis einer ID abrufbar sein. Datenbank und Dokumente müssen
gemeinsam wiederherstellbar bleiben.

## Entscheidung

Originale und generierte PDFs liegen in einem dedizierten persistenten Volume
außerhalb von `priv/static` und außerhalb des Release-Verzeichnisses.

- Die Datenbank speichert Eigentümer, Antragsbezug, Dokumentart,
  Originalanzeigename, zufälligen internen Schlüssel, Größe, Seitenzahl,
  SHA-256, MIME-Typ und Zeitstempel.
- Der interne Schlüssel enthält 256 Bit kryptographischen Zufall und wird nie
  aus Benutzerangaben oder einer Primär-ID gebildet.
- Verzeichnisse sind `0700`, Dateien `0600`; der Phoenix-Betriebsbenutzer ist
  der einzige Laufzeitbesitzer.
- Downloads werden ausschließlich über einen Controller mit `current_scope`
  und Eigentumsprüfung gestreamt. Es gibt keine öffentlichen URLs oder
  presigned Links.
- Ersetzung schreibt zuerst eine neue Datei atomar und entfernt die alte erst
  nach erfolgreicher Datenbanktransaktion. Löschung ist wiederholbar und wird
  protokolliert, ohne Dateinamen oder Inhalte zu loggen.
- PostgreSQL und Dokumentvolume werden als eine Sicherungseinheit behandelt.
  Backup und Restore müssen verschlüsselt und gemeinsam getestet werden.

Das Produktionsvolume wird auf Host-/Storage-Ebene verschlüsselt. IBAN und BIC
werden zusätzlich auf Anwendungsebene per authentifizierter
Envelope-Verschlüsselung gespeichert. Der aktive Schlüssel kommt ausschließlich
aus einem Laufzeit-Secret; Datensätze tragen eine Schlüsselversion für spätere
Rotation. In Logs, Telemetrie, Fehlern und Suchindizes erscheinen weder
Bankdaten noch Dokumentinhalte.

## Folgen

Der lokale Volume-Ansatz passt zur privaten Zwei-Personen-Anwendung und ist
einfach zu sichern. Eine spätere Object-Storage-Implementierung bleibt möglich,
wenn der Documents-Kontext statt direkter Dateizugriffe verwendet wird.
Verschlüsselung ersetzt weder Scope-Prüfungen noch restriktive
Dateiberechtigungen.
