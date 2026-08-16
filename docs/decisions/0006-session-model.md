# ADR 0006: Sitzungen im Cookie ohne serverseitigen Widerruf

- Status: akzeptiert
- Datum: 2026-08-16
- Betrifft: C01, C06

## Kontext

Nach erfolgreicher OIDC-Anmeldung hält die Anwendung keine Sitzungstabelle. Der
verschlüsselte und signierte Sitzungscookie enthält `user_id`, einen absoluten
Ablaufzeitpunkt und den `id_token_hint` für die Abmeldung bei Authentik. Bei
jeder Anfrage wird daraus der `current_scope` rekonstruiert.

Daraus folgt: Ein abgegriffener Cookie bleibt bis zu seinem Ablauf gültig. Weder
eine Abmeldung auf einem anderen Gerät noch eine Sperrung des Kontos in
Authentik erreicht ihn. Es gibt keine Liste aktiver Sitzungen und keinen Weg,
eine einzelne davon gezielt zu beenden.

Ein Sicherheitsaudit hat das aufgeworfen. Es war bislang Verhalten, keine
festgehaltene Entscheidung.

## Entscheidung

Sitzungen bleiben zustandslos im Cookie. Es wird keine Sitzungstabelle
eingeführt.

Begründung:

- Die Anwendung ist laut [ADR 0004](0004-sensitive-storage.md) eine private
  Anwendung für zwei Personen mit einer überschaubaren Zahl bekannter Geräte.
  Der Nutzen einer Sitzungsübersicht — fremde Sitzungen entdecken und einzeln
  beenden — setzt eine Gerätevielfalt voraus, die es hier nicht gibt.
- Eine Sitzungstabelle verlagert Zustand in die Datenbank, den es sonst nicht
  gäbe: eine Abfrage je Anfrage, ein Aufräumjob für abgelaufene Zeilen und ein
  weiterer Datensatz mit Bezug zu Anmeldezeitpunkten und Geräten.
- Für den Fall, der wirklich zählt — ein Cookie ist abhandengekommen — existiert
  bereits ein wirksamer Hebel, siehe unten.

Die Entscheidung stützt sich auf folgende Eigenschaften, die verbindlich sind:

- Der Ablauf ist **absolut, nicht gleitend**. `expires_at` wird bei der
  Anmeldung einmal gesetzt (Vorgabe acht Stunden) und durch Aktivität nie
  verlängert. Eine Sitzung endet spätestens nach dieser Frist, unabhängig davon,
  wie intensiv sie genutzt wird.
- Verbundene LiveView-Sitzungen werden **zum Ablaufzeitpunkt selbst** beendet,
  nicht erst bei der nächsten HTTP-Anfrage.
- Der Cookie ist verschlüsselt und signiert, `http_only`, `same_site=Lax` und in
  Produktion `secure`. Die Anwendung erzwingt HTTPS über HSTS.
- Authentifizierte Antworten werden mit `Cache-Control: private, no-store`
  ausgeliefert und dürfen nicht eingebettet werden
  (`frame-ancestors 'none'`).
- Der `id_token_hint` ermöglicht die RP-initiierte Abmeldung bei Authentik, die
  zusätzlich die dortige Sitzung beendet.

## Notfallwiderruf

Der einzige unterstützte Weg, sämtliche Sitzungen sofort zu beenden, ist die
Rotation von `SECRET_KEY_BASE` in der Environment-Datei mit anschließendem
Neustart. Damit werden alle ausgestellten Cookies ungültig; alle Benutzer melden
sich neu an. Das ist ein grobes, aber sofort wirksames Werkzeug und für eine
Installation dieser Größe angemessen.

Ausdrücklich **kein** unterstützter Weg ist das Löschen des Benutzerdatensatzes.
Er würde zwar die Sitzung entwerten, reißt über `on_delete: :delete_all` aber
sämtliche Anträge, Dokumente und Ausgaben mit sich.

## Folgen

`FahrgastrechteWeb.UserAuth` bleibt ohne Datenbankzugriff für die Sitzung selbst;
gelesen wird nur der Benutzer, auf den der Cookie zeigt.

Nicht abgedeckt bleibt damit: ein entwendeter Cookie ist bis zu acht Stunden
brauchbar, eine Kontosperrung in Authentik wirkt erst danach, und eine Abmeldung
betrifft nur das Gerät, auf dem sie ausgelöst wurde. Wer das nicht hinnehmen
will, muss die Frist verkürzen — `session_ttl_seconds` in der
Authentik-Konfiguration — oder `SECRET_KEY_BASE` rotieren.

Sobald die Anwendung mehr Benutzer, unbekannte Geräte oder einen
Fernzugriff-Anwendungsfall bekommt, ist diese Entscheidung nicht mehr tragfähig.
Dann ersetzt ein neues Decision Record dieses hier und führt eine Sitzungstabelle
mit Zufallstoken, letzter Nutzung und gezieltem Widerruf ein.
