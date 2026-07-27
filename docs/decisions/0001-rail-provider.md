# ADR 0001: Timetables als erste Bahndatenquelle

- Status: akzeptiert
- Datum: 2026-07-27
- Betrifft: C00, C04

## Kontext

Der Antrag benötigt Bahnhofssuche, Sollzeiten, Zuglauf, Prognose-/Istzeiten und
Ausfälle. Die verfügbaren DB-Produkte unterscheiden sich deutlich in Zugang,
Lizenz, Kosten und zeitlicher Abdeckung.

Die offizielle
[Timetables-API](https://developers.deutschebahn.com/db-api-marketplace/apis/product/timetables)
bietet im kostenfreien Plan 60 Aufrufe pro Minute und steht unter CC BY 4.0. Sie
liefert:

- `/station/{pattern}` für Bahnhofssuche und EVA-Nummern,
- `/plan/{evaNo}/{date}/{hour}` für statische Sollhalte eines Stundenfensters,
- `/fchg/{evaNo}` für alle aktuell bekannten Änderungen und
- `/rchg/{evaNo}` für Änderungen, die in den letzten zwei Minuten bekannt
  wurden.

`fchg` entfernt Änderungen wieder, sobald sie am jeweiligen Bahnhof nicht mehr
aktuell sind. Timetables ist damit keine historische Datenquelle. Die
Fahrt-ID setzt sich aus einer tagesbezogenen Fahrt-ID, Datum und Haltindex
zusammen; ihr tagesbezogener Anteil kann an Folgetagen wiederverwendet werden.

Die RIS-Produkte
[Journeys](https://developers.deutschebahn.com/db-api-marketplace/apis/product/ris-journeys-transporteure),
[Boards](https://developers.deutschebahn.com/db-api-marketplace/apis/product/ris-boards-transporteure),
[Connections](https://developers.deutschebahn.com/db-api-marketplace/apis/product/ris-connections-netz)
und
[Stations](https://developers.deutschebahn.com/db-api-marketplace/apis/product/ris-stations)
bieten reichhaltigere normalisierte Daten. Der Zugang wird jedoch geprüft und
vertraglich vereinbart. Journeys kann einzelne Fahrten suchen oder zuordnen;
Connections liefert Anschlüsse zu einer Ankunft. Keines der geprüften Produkte
ist eine allgemeine Start-Ziel-Reiseauskunft für mehrgliedrige Reisen.

## Entscheidung

Der erste Adapter in C04 verwendet Timetables über die bereits vorhandene
`Req`-Bibliothek. Der Vertrag ist
`Fahrgastrechte.Rail.Provider`; externe Antworten verlassen den Adapter nicht.

- Eine externe ID wird immer zusammen mit dem Provider gespeichert.
- EVA-Nummern identifizieren Bahnhöfe innerhalb dieses Providers.
- Fahrt- und Halt-IDs werden nicht als dauerhaft oder providerübergreifend
  stabil behandelt.
- Jeder erfolgreiche Abruf wird mit Abrufzeit, normalisierten Werten und
  unverändertem API-Snapshot am Antrag gespeichert.
- Die Anwendung begrenzt sich auf 45 Requests pro Minute und höchstens zwei
  parallele Requests. `429` berücksichtigt `Retry-After`; höchstens zwei
  idempotente Wiederholungen sind erlaubt.
- Das UI verspricht keine historischen Ist-Daten. Nach Abfahrt können Daten
  bereits fehlen. Fehlende Daten führen sofort zum manuellen Ersatzweg.

## Rekonstruktionsweg

1. Start, Ziel, Reisetag und optionale Zugnummer werden aus bestätigten
   Ticketvorschlägen oder manueller Eingabe übernommen.
2. `/station` löst Namen in EVA-Nummern auf.
3. `/plan` lädt die in Frage kommenden Abfahrten am Startbahnhof.
4. Zugnummer, Sollzeit und Fahrweg grenzen Kandidaten ein.
5. Für aktuelle Reisen werden `/fchg` und danach optional `/rchg` korreliert.
6. Umstiege werden segmentweise rekonstruiert und vom Benutzer bestätigt.
7. Ist kein eindeutiger Kandidat verfügbar, wird nichts automatisch gewählt.

Ein später verfügbarer RIS-Zugang wird als eigener Adapter implementiert. Eine
echte Reiseplanungs-API kann den optionalen Callback `search_connections/2`
bedienen; der Timetables-Adapter gibt dafür `{:error, :unsupported}` zurück.

## Folgen

Der MVP bleibt mit dem kostenfreien Zugang entwickelbar, ist aber für ältere
Reisen bewusst auf manuelle Eingabe angewiesen. API-Werte sind stets
Vorschläge. Die Architektur kann später ohne Änderung der Fachkontexte auf RIS
oder einen lizenzierten Reiseplaner wechseln.

## Verifikation

Der authentifizierte, geheimnisfreie Smoke-Test ist unter
[`scripts/c00/db_api_smoke.exs`](../../scripts/c00/db_api_smoke.exs)
dokumentiert. Er gibt weder Header noch Antwortinhalt aus.
