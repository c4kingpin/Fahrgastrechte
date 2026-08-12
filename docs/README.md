# Dokumentation

Dieser Index trennt dauerhafte Referenzdokumentation von historischen
Planungs- und Spike-Artefakten.

## Einstieg

- [Technische Übersicht](architecture.md): Systemgrenze, Fachkontexte,
  Hauptabläufe und Qualitätsgrenze
- [Öffentliche Kontextschnittstellen](interfaces/README.md): Verträge von
  Claims, Documents/Tickets, Rail und Exports
- [Refactoring-Roadmap](refactoring-roadmap.md): geprüfte, noch offene
  kontextübergreifende Arbeiten

## Lokale Entwicklung und Konfiguration

- Die [Projekt-README](../README.md) enthält Quickstart, Datenbankvariablen und
  Entwicklungsbefehle.
- [Authentik-Integration](integrations/authentik.md) beschreibt OIDC,
  Entwicklungsidentität, Session und Feldverschlüsselung.
- [Technische Spikes](spikes/c00/README.md) erklären reproduzierbare
  Voruntersuchungen; sie sind keine Produktionsanleitung.

## Produktion und Betrieb

1. [Installation im vorhandenen Debian-LXC](deployment/proxmox-lxc.md)
2. [Zoraxy, TLS und Netzgrenze](deployment/zoraxy.md)
3. [Betriebshandbuch](deployment/operations.md)
4. [Betriebsabnahme](deployment/acceptance.md)

Der unterstützte öffentliche Installationseinstieg ist
`install/fahrgastrechte-install.sh`. `ct/fahrgastrechte.sh` ist ein
Kompatibilitäts-Bootstrap; Skripte unter `scripts/deploy/` sind
Repository-Helfer beziehungsweise installierte Betriebswerkzeuge.

## Architekturentscheidungen

Die [Architecture Decision Records](decisions/README.md) sind verbindliche
Entscheidungen. Neue Erkenntnisse ersetzen einen ADR durch einen neuen Eintrag,
statt die ursprüngliche Entscheidung rückwirkend umzudeuten.

## Historische Referenz

Der [Komponenten- und Wellenplan](implementation-plan/README.md) sowie das
[Baseline-Protokoll vom 30. Juli 2026](implementation-plan/baseline-2026-07-30.md)
dokumentieren Entstehung und damalige Abnahmekriterien. Für den aktuellen
Systemvertrag sind Code, Tests, die technische Übersicht und die
Kontextschnittstellen maßgeblich.
