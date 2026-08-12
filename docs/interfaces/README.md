# Öffentliche Kontextschnittstellen

Diese Dokumente beschreiben die dauerhaften Verträge zwischen den Fachkontexten.
Aufrufer verwenden ausschließlich die öffentlichen, benutzerbezogenen
Funktionen; direkte Tabellenzugriffe über Kontextgrenzen hinweg sind nicht
vorgesehen.

| Kontext | Vertrag |
| --- | --- |
| `Claims` | [Antragsdomäne, Locking und Status](c02-claims.md) |
| `Documents` und `Tickets` | [Dokumente, Analyse und Vorschläge](c03-documents-tickets.md) |
| `Rail` | [Provider, Snapshots und Reiseverläufe](c04-rail.md) |
| `Exports` | [Bereitschaft und versionierte PDF-Ausgaben](c05-exports.md) |

Die Systemgrenze und das Zusammenspiel dieser Kontexte fasst die
[technische Übersicht](../architecture.md) zusammen. Änderungen an einem
öffentlichen Vertrag müssen gleichzeitig in Code, Tests und dem zugehörigen
Dokument nachgeführt werden.
