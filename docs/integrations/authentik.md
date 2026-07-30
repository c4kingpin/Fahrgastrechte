# Authentik-Integration (Welle 2)

## Aktueller Stand

Die Anwendung verwendet Authentik als OpenID-Connect-Provider. Implementiert
sind Authorization Code Flow mit PKCE (`S256`), einmaliges `state`, `nonce`,
Codeaustausch, ID-Token-Prüfung, lokale Sitzungen und RP-initiierter Logout.

Die öffentlichen Endpunkte sind:

- `GET /anmelden` – startet den OIDC-Flow
- `GET /auth/callback` – verarbeitet genau einen gebundenen Callback
- `DELETE /abmelden` – löscht die lokale Sitzung und öffnet Authentiks
  End-Session-Endpunkt
- `GET /auth/abgemeldet` – bestätigt den Rückweg nach dem Provider-Logout

Die stabile lokale Zuordnung verwendet ausschließlich das eindeutige Paar
`(issuer, subject)`. E-Mail und Anzeigename sind veränderliche Metadaten und
werden niemals zur Benutzerzuordnung verwendet. In `dev` bleibt die explizit
konfigurierte lokale Identität verfügbar; in `test` und `prod` ist dieser
Fallback deaktiviert.

## Authentik konfigurieren

In Authentik wird eine Anwendung mit einem vertraulichen OAuth2/OpenID-Connect-
Provider angelegt. Für die Produktionsadresse
`https://fahrgastrechte.example.org` gelten diese Werte:

- Client-Typ: `Confidential`
- Grant: `Authorization Code`
- PKCE: `S256`
- Scopes: `openid`, `profile`, `email`
- Signaturschlüssel: ausgewählter asymmetrischer RSA-Schlüssel (`RS256`)
- strikte Authorization-Redirect-URI:
  `https://fahrgastrechte.example.org/auth/callback`
- strikte Logout-Redirect-URI:
  `https://fahrgastrechte.example.org/auth/abgemeldet`

Ein ausgewählter Signaturschlüssel ist verbindlich. Ohne ihn kann Authentik
Tokens symmetrisch mit dem Client-Secret signieren; die Anwendung akzeptiert
bewusst nur die über JWKS prüfbare RSA-Signatur.

`AUTHENTIK_ISSUER` muss exakt dem `issuer` des Discovery-Dokuments entsprechen,
im empfohlenen providerbezogenen Modus beispielsweise:

```text
https://authentik.example.org/application/o/fahrgastrechte/
```

## Laufzeitkonfiguration

In `/etc/fahrgastrechte/fahrgastrechte.env` werden gesetzt:

```text
AUTHENTIK_ISSUER=https://authentik.example.org/application/o/fahrgastrechte/
AUTHENTIK_CLIENT_ID=<client-id>
AUTHENTIK_CLIENT_SECRET=<client-secret>
```

Danach wird `fahrgastrechte.service` neu gestartet. Redirect- und
Post-Logout-URI erzeugt die Anwendung ausschließlich aus dem kanonischen
Produktionshost `PHX_HOST`; Request-Host-Header beeinflussen sie nicht. Fehlt
die Konfiguration oder ist Authentik nicht erreichbar, bleibt die Anwendung
betriebsbereit, zeigt beim Anmeldeversuch aber eine neutrale Fehlermeldung.

## Sicherheitsprüfungen

`Fahrgastrechte.Accounts.Authentik` akzeptiert eine Identität erst nach diesen
Prüfungen:

1. Discovery, Token- und JWKS-Endpunkte verwenden HTTPS und denselben Origin
   wie der konfigurierte Issuer; Serveraufrufe folgen keinen Redirects.
2. Der Callback gehört über konstantzeitlich verglichenes `state` zum höchstens
   zehn Minuten alten Login-Versuch und kann nur einmal verwendet werden.
3. Der Code wird mit dem gebundenen PKCE-Verifier ausgetauscht.
4. Der JWT-Header erlaubt nur `RS256`, einen eindeutigen `kid` und einen
   passenden RSA-Signaturschlüssel aus dem JWKS.
5. Signatur, `iss`, `aud`, gegebenenfalls `azp`, `exp`, `iat`, `nonce` und ein
   nicht leeres `sub` werden geprüft.
6. Access- und Refresh-Tokens werden nicht gespeichert. Das ID-Token bleibt
   nur als Logout-Hinweis in der verschlüsselten Browser-Session.

## Session und Scope

Nach erfolgreicher Tokenprüfung erneuert die Anwendung die Browser-Session.
Sie ist standardmäßig acht Stunden gültig; nach Ablauf werden Session und
Identitätsdaten entfernt und eine verständliche erneute Anmeldung angeboten.

Der Browser-Stack setzt `current_scope` nur aus einer gültigen Sitzung.
Geschützte Controller verwenden die Pipeline `:authenticated`; geschützte
LiveViews die gleichnamige `live_session` mit `UserAuth.on_mount/4`.
Kontextfunktionen für benutzerbezogene Daten erwarten immer diesen Scope.

Session-Cookies sind verschlüsselt und signiert sowie explizit `HttpOnly`,
`SameSite=Lax` und in Produktion `Secure`. Nur `dev` und `test` erlauben Cookies
über lokales HTTP.

## Feldverschlüsselung

IBAN und BIC werden unabhängig von der OIDC-Sitzung mit AES-256-GCM
verschlüsselt. In Produktion sind folgende Runtime-Secrets
Pflicht:

```bash
export FIELD_ENCRYPTION_KEY="$(openssl rand -base64 32)"
export FIELD_ENCRYPTION_KEY_VERSION="1"
```

Der Schlüssel gehört ausschließlich in den Secret Store der Laufzeit, niemals
in `.env`-Dateien oder das Repository. Jeder Datensatz trägt seine
Schlüsselversion; `BankDataCipher` akzeptiert intern mehrere Versionen, damit
die spätere Rotation ohne Schemaänderung ergänzt werden kann.
