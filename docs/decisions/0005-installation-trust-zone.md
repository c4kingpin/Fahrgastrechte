# ADR 0005: Installation als eine Vertrauenszone

- Status: akzeptiert
- Datum: 2026-08-16
- Betrifft: C01, C06, Referenzdaten

## Kontext

Fahrgastrechte kennt genau eine Berechtigungsstufe: angemeldet oder nicht.
Benutzerbezogene Daten sind konsequent an `current_scope` gebunden — Anträge,
Dokumente, Vorschläge, Reisen und Ausgaben eines Benutzers sind für andere
Benutzer weder lesbar noch änderbar.

Zwei Datenquellen fallen bewusst aus diesem Muster heraus: das offizielle
Fahrgastrechteformular und die CSV-Projektion der Bahn-Vorhersage-Exporte.
Beide gelten installationsweit. `ReferenceData.replace_official_form/3` und
`replace_bahn_archive/3` prüfen deshalb nur, *dass* ein Benutzer angemeldet ist,
nicht *welcher*. Jeder angemeldete Benutzer kann damit eine Quelle aktivieren,
die alle künftig erzeugten Ausgaben der Installation betrifft — auch die
anderer Benutzer.

Ein Sicherheitsaudit hat diesen Umstand aufgeworfen. Er war bislang nirgends als
Entscheidung festgehalten, sondern nur als Verhalten vorhanden.

## Entscheidung

Eine Installation ist eine Vertrauenszone. Es wird kein Rollenmodell eingeführt.

Begründung:

- Die Anwendung ist laut [ADR 0004](0004-sensitive-storage.md) eine private
  Anwendung für zwei Personen, die einander bereits vertrauen. Eine
  Rollentrennung würde eine Grenze modellieren, die es zwischen diesen
  Personen nicht gibt.
- Wer Referenzdaten manipulieren wollte, bräuchte ein gültiges
  Authentik-Konto dieser Installation. Wer das hat, ist kein Angreifer von
  außen, sondern ein legitimer Mitbenutzer.
- Ein Rollenmodell mit genau einem Administrator in einer Zwei-Personen-
  Installation erzeugt Betriebsaufwand (Migration, Rechtevergabe, Notfallzugang
  bei Abwesenheit) ohne Sicherheitsgewinn gegenüber dem Vertrauen, das durch
  die gemeinsame Nutzung ohnehin vorausgesetzt wird.

Diese Entscheidung deckt ausschließlich installationsweite Betriebsdaten. Sie
ändert nichts an der Trennung benutzerbezogener Daten: eine nackte ID berechtigt
weiterhin zu nichts, und kein Benutzer sieht Anträge, Dokumente oder Bankdaten
eines anderen.

Damit die Reichweite einer Aktivierung sichtbar bleibt, gilt:

- Die Oberfläche unter `/datenquellen` weist ausdrücklich darauf hin, dass eine
  Aktivierung alle künftig erzeugten Ausgaben der Installation betrifft.
- Jede Version wird unveränderlich mit hochladendem Benutzer, Zeitpunkt,
  Herkunfts-URL, Größe und SHA-256 gespeichert; `list_versions/2` gibt die
  vollständige Historie aus. Eine Änderung ist damit nachträglich einer Person
  zuzuordnen.
- Bereits erzeugte Ausgaben bleiben unberührt. `ExportVersion` hält
  Formularversion, Quelle und SHA-256 der tatsächlich verwendeten Vorlage fest,
  sodass ein abgeschickter Antrag nachvollziehbar bleibt, auch wenn die aktive
  Quelle später wechselt.

## Folgen

Die Referenzdaten-API bleibt ohne Rollenprüfung; ein `%Scope{}` genügt. Tests,
die eine fehlende Berechtigung erwarten, prüfen weiterhin nur den
unauthentifizierten Fall.

Sobald eine Installation über den privaten Zwei-Personen-Rahmen hinauswächst —
mehrere Haushalte, eine Beratungsstelle, geteilter Betrieb — ist diese
Entscheidung nicht mehr tragfähig. Dann ersetzt ein neues Decision Record dieses
hier und führt eine Rolle ein, die Schreibzugriff auf Referenzdaten von der
bloßen Anmeldung trennt. Die Historie mit hochladendem Benutzer ist bereits
vorhanden und würde eine solche Einführung nicht behindern.

Ausdrücklich nicht abgedeckt: kompromittierte Konten. Wird ein Konto der
Installation übernommen, kann darüber auch die Formularvorlage getauscht werden.
Dagegen schützen die Authentik-Anmeldung und die Validierung beim Upload — eine
neue Vorlage muss den vollständigen Feldvertrag aus dem Manifest erfüllen,
strukturell gültig, unverschlüsselt und A4 sein —, nicht aber eine Rollenprüfung.
