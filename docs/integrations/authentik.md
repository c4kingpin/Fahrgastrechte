# Authentik-Integration (C01, vorbereitet)

## Aktueller Stand

C01 führt **noch keine echte Authentifizierung** aus. Es gibt weder Login- und
Callback-Endpunkte noch Tokenaustausch oder einen Logout bei Authentik.

In `dev` erzeugt `FahrgastrechteWeb.UserAuth` stattdessen genau eine deutlich
als lokal gekennzeichnete, synthetische Identität. Sie wird über dieselbe
Accounts-Schnittstelle wie eine spätere OIDC-Identität einem lokalen Benutzer
zugeordnet. In `test` und `prod` ist dieser Fallback deaktiviert; geschützte
Routen bleiben dort ohne gültige Session geschlossen.

Die stabile lokale Zuordnung verwendet ausschließlich das eindeutige Paar
`(issuer, subject)`. E-Mail und Anzeigename sind veränderliche Metadaten und
werden niemals zur Benutzerzuordnung verwendet.

## Vorbereitete Grenze

Ein späterer Authentik-Adapter implementiert
`Fahrgastrechte.Accounts.IdentityProvider`. Erst nach vollständiger Prüfung
darf er eine `Fahrgastrechte.Accounts.Identity` an
`Fahrgastrechte.Accounts.register_identity/1` übergeben.

Der Adapter muss mindestens Folgendes leisten:

1. Authorization Code Flow mit PKCE starten und `state` sowie `nonce` in der
   serverseitig geschützten Session binden.
2. Callback, Codeaustausch und Discovery ausschließlich gegen den
   konfigurierten HTTPS-Issuer ausführen.
3. Signatur und Algorithmus über die zum Issuer gehörenden JWKS prüfen.
4. `iss`, `aud`, `exp`, `iat`, `state` und `nonce` strikt validieren.
5. Nur das validierte Paar `iss`/`sub` als stabile Identität übernehmen.
6. Beim Logout die lokale Session erneuern/löschen und anschließend den
   End-Session-Endpunkt des Providers verwenden.

Vorgesehene Laufzeit-Secrets sind `AUTHENTIK_ISSUER`,
`AUTHENTIK_CLIENT_ID` und `AUTHENTIK_CLIENT_SECRET`. Redirect- und
Post-Logout-URI werden aus dem kanonischen Produktionshost gebildet. Bis der
Adapter implementiert ist, wertet die Anwendung diese Variablen bewusst nicht
aus und bietet keinen scheinbar funktionierenden Login an.

## Session und Scope

Der Browser-Stack setzt `current_scope` aus der signierten Session. Geschützte
Controller verwenden die Pipeline `:authenticated`; geschützte LiveViews die
gleichnamige `live_session` mit `UserAuth.on_mount/4`. Kontextfunktionen für
benutzerbezogene Daten erwarten immer diesen Scope.

Session-Cookies sind explizit `HttpOnly`, `SameSite=Lax` und in Produktion
`Secure`. Nur `dev` und `test` erlauben Cookies über lokales HTTP.

## Feldverschlüsselung

IBAN und BIC werden unabhängig von der noch fehlenden OIDC-Anbindung bereits
mit AES-256-GCM verschlüsselt. In Produktion sind folgende Runtime-Secrets
Pflicht:

```bash
export FIELD_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export FIELD_ENCRYPTION_KEY_VERSION="1"
```

Der Schlüssel gehört ausschließlich in den Secret Store der Laufzeit, niemals
in `.env`-Dateien oder das Repository. Jeder Datensatz trägt seine
Schlüsselversion; `BankDataCipher` akzeptiert intern mehrere Versionen, damit
die spätere Rotation ohne Schemaänderung ergänzt werden kann.
