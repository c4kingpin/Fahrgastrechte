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

[Bahn-Vorhersage](https://bahnvorhersage.de/open-data/) veröffentlicht dagegen
historische, aus Timetables-Beobachtungen abgeleitete Daten. Der empfohlene
[geparste Datensatz](https://bahnvorhersage.de/open-data/parsed-train-delays/)
deckt laut Anbieter nahezu alle Zugbewegungen in Deutschland seit September
2021 ab und wird als jährliches Paket mit täglichen Parquet-Dateien
bereitgestellt. Neue Pakete erscheinen erst nach Abschluss des jeweiligen
Jahres. Der Anbieter kennzeichnet den Datensatz als unvollständig und ohne
Gewähr.

Die öffentliche Web-API von Bahn-Vorhersage darf laut
[FAQ](https://bahnvorhersage.de/) nicht von anderen Anwendungen verwendet
werden. Veröffentlicht werden stattdessen Daten und trainierte Modelle. Der
geparste Datensatz steht unter ODbL; die geforderte Attribution nennt
Bahn-Vorhersage, Deutsche Bahn, Trainline und DELFI.

## Entscheidung

Der erste Adapter in C04 verwendet Timetables über die bereits vorhandene
`Req`-Bibliothek. Der Vertrag ist
`Fahrgastrechte.Rail.Provider`; externe Antworten verlassen den Adapter nicht.

C04 erhält zusätzlich einen read-only
`Fahrgastrechte.Rail.Providers.BahnVorhersageArchive`-Adapter. Er ruft weder
die Website noch die Web-API von Bahn-Vorhersage auf. Ein Administrator stellt
stattdessen ausdrücklich heruntergeladene Jahresarchive und den zugehörigen
Haltestellendatensatz lokal bereit; der Import läuft außerhalb eines
Benutzer-Requests. Fehlt ein passendes Archiv, meldet der Adapter
`{:error, :history_unavailable}`.

- Eine externe ID wird immer zusammen mit dem Provider gespeichert.
- EVA-Nummern identifizieren Bahnhöfe innerhalb dieses Providers.
- Fahrt- und Halt-IDs werden nicht als dauerhaft oder providerübergreifend
  stabil behandelt.
- Jeder erfolgreiche Abruf wird mit Abrufzeit, normalisierten Werten und
  unverändertem API-Snapshot am Antrag gespeichert.
- Jeder Archivimport speichert Anbieter, Datensatzversion, Lizenz,
  Attributionshinweis und SHA-256 der Quelldateien. Eine Weitergabe einer
  abgeleiteten Datenbank muss die ODbL-Bedingungen berücksichtigen.
- Die Anwendung begrenzt sich auf 45 Requests pro Minute und höchstens zwei
  parallele Requests. `429` berücksichtigt `Retry-After`; höchstens zwei
  idempotente Wiederholungen sind erlaubt.
- Das UI verspricht keine vollständigen historischen Ist-Daten. Nach Abfahrt
  können Timetables-Daten bereits fehlen, Archive können Lücken haben und das
  laufende Jahr ist regulär noch nicht veröffentlicht. Fehlende Daten führen
  sofort zum manuellen Ersatzweg.

Im Archiv wird `time_real` nur bei `is_final == true` als `actual_at`
normalisiert. Andernfalls bleibt der Wert eine Prognose (`estimated_at`).
`update_timestamp`, `is_cancelled` und die minutengenaue UTC-Zeit werden als
Herkunftsmetadaten erhalten. Die gehashte `trip_id` ist ausschließlich im
Namespace des Archivproviders gültig.

## Rekonstruktionsweg

1. Start, Ziel, Reisetag und optionale Zugnummer werden aus bestätigten
   Ticketvorschlägen oder manueller Eingabe übernommen.
2. Bahnhofsnamen werden in providergebundene Haltestellen-IDs aufgelöst.
3. Deckt ein lokal importiertes Bahn-Vorhersage-Archiv den Reisetag ab, sucht
   der Archivprovider Halte nach Bahnhof, Sollzeit, Kategorie und Zugnummer.
4. Andernfalls lädt Timetables über `/plan` die in Frage kommenden Abfahrten.
5. Zugnummer, Sollzeit und Fahrweg grenzen Kandidaten ein.
6. Für aktuelle Reisen werden `/fchg` und danach optional `/rchg` korreliert.
7. Umstiege werden segmentweise rekonstruiert und vom Benutzer bestätigt.
8. Ist kein eindeutiger Kandidat verfügbar, wird nichts automatisch gewählt.

Ein später verfügbarer RIS-Zugang wird als eigener Adapter implementiert. Eine
echte Reiseplanungs-API kann den optionalen Callback `search_connections/2`
bedienen; der Timetables-Adapter gibt dafür `{:error, :unsupported}` zurück.

## Folgen

Der MVP bleibt mit dem kostenfreien Zugang entwickelbar. Importierte
Bahn-Vorhersage-Archive können ältere Reisen ergänzen, ersetzen wegen ihrer
Verzögerung und möglichen Lücken aber nicht die manuelle Eingabe. Live- und
Archivwerte sind stets Vorschläge. Die Architektur kann später ohne Änderung
der Fachkontexte auf RIS oder einen lizenzierten Reiseplaner wechseln.

## Verifikation

Der authentifizierte, geheimnisfreie Smoke-Test ist unter
[`scripts/c00/db_api_smoke.exs`](../../scripts/c00/db_api_smoke.exs)
dokumentiert. Er gibt weder Header noch Antwortinhalt aus. Eine synthetische
Projektion des Bahn-Vorhersage-Parquet-Schemas liegt unter
[`test/fixtures/c00/bahnvorhersage-parsed-delays.csv`](../../test/fixtures/c00/bahnvorhersage-parsed-delays.csv).
