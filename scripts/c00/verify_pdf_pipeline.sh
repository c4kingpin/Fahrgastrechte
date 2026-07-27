#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
FIXTURE_DIR="${PROJECT_DIR}/test/fixtures/c00"
FORM_URL="https://cms.static-bahn.de/wmedia/redaktion/aushaenge/fahrgastrechte/Fahrgastrechte-Formular_deutsch-feb25-2.pdf"
FORM_SHA256="4a30f9c7f00593bf5bda1b6eaa2d1b6e293357faa48631a1d7e2ade3b77a39a9"
FONT_PATH="/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

for command_name in cmp curl pdfinfo pdftk pdftocairo pdftoppm pdftotext qpdf sha256sum strings timeout; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "missing command: ${command_name}" >&2
    exit 2
  fi
done

if [[ ! -f "${FONT_PATH}" ]]; then
  echo "missing font: ${FONT_PATH}" >&2
  exit 2
fi

TICKET_PATH="${FIXTURE_DIR}/synthetic-ticket-flexpreis.pdf"
INVOICE_PATH="${FIXTURE_DIR}/synthetic-invoice.pdf"

for fixture_path in "${TICKET_PATH}" "${INVOICE_PATH}"; do
  if [[ ! -f "${fixture_path}" ]]; then
    echo "missing fixture: ${fixture_path}" >&2
    echo "run: mix run --no-start scripts/c00/generate_pdf_fixtures.exs" >&2
    exit 2
  fi
done

WORK_DIR="$(mktemp -d)"
chmod 0700 "${WORK_DIR}"

cleanup() {
  rm -rf -- "${WORK_DIR}"
}
trap cleanup EXIT

SOURCE_FORM_PATH="${WORK_DIR}/official-form-source.pdf"
FORM_PATH="${WORK_DIR}/official-form-normalized.pdf"
XFDF_PATH="${WORK_DIR}/synthetic-values.xfdf"
FILLED_FORM_PATH="${WORK_DIR}/filled-form.pdf"
FLATTENED_FORM_PATH="${WORK_DIR}/flattened-form.pdf"
SANITIZED_FORM_PATH="${WORK_DIR}/sanitized-form.pdf"
SANITIZED_TICKET_PATH="${WORK_DIR}/sanitized-ticket.pdf"
SANITIZED_INVOICE_PATH="${WORK_DIR}/sanitized-invoice.pdf"
BUNDLE_PATH="${WORK_DIR}/bundle.pdf"
BUNDLE_TEXT_PATH="${WORK_DIR}/bundle.txt"
BUNDLE_QDF_PATH="${WORK_DIR}/bundle-qdf.pdf"
BUNDLE_STRINGS_PATH="${WORK_DIR}/bundle-strings.txt"
TICKET_TEXT_PATH="${WORK_DIR}/ticket.txt"

timeout 30 curl --fail --location --silent --show-error \
  "${FORM_URL}" \
  --output "${SOURCE_FORM_PATH}"

if ! printf '%s  %s\n' "${FORM_SHA256}" "${SOURCE_FORM_PATH}" | sha256sum --check --status; then
  echo "official form checksum changed; review it as a new template version" >&2
  exit 1
fi

qpdf_status=0
timeout 10 qpdf \
  "${SOURCE_FORM_PATH}" \
  "${FORM_PATH}" \
  >/dev/null 2>"${WORK_DIR}/qpdf-normalize.log" || qpdf_status=$?

if [[ "${qpdf_status}" != "0" && "${qpdf_status}" != "3" ]]; then
  echo "qpdf could not normalize the official form" >&2
  exit 1
fi

for pdf_path in "${FORM_PATH}" "${TICKET_PATH}" "${INVOICE_PATH}"; do
  timeout 10 qpdf --check "${pdf_path}" >/dev/null

  if ! timeout 10 pdfinfo "${pdf_path}" | grep -Fq '(A4)'; then
    echo "non-A4 input: ${pdf_path}" >&2
    exit 1
  fi
done

FIELD_DUMP="$(timeout 10 pdftk "${FORM_PATH}" dump_data_fields_utf8)"

required_fields=(
  journey
  planned_day
  planned_month
  planned_year
  planned_direction
  planned_departure_station
  planned_departure_hours
  planned_departure_minutes
  planned_destination_station
  planned_destination_hours
  planned_destination_minutes
  arrived_day
  arrived_month
  arrived_year
  arrived_hours
  arrived_minutes
  ticket_digital
  ticket_digital_number
  compensation
  compensation_accountholder
  compensation_iban
  compensation_bic
  personal
  personal_firstname
  personal_lastname
  personal_street
  personal_housenumber
  personal_postcode
  personal_city
  date
  signature
)

for field_name in "${required_fields[@]}"; do
  if [[ "${FIELD_DUMP}" != *"FieldName: ${field_name}"* ]]; then
    echo "missing form field: ${field_name}" >&2
    exit 1
  fi
done

cat >"${XFDF_PATH}" <<'XFDF'
<?xml version="1.0" encoding="UTF-8"?>
<xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
  <fields>
    <field name="journey"><value>Verspätung am Ziel (mind. 60 Minuten)</value></field>
    <field name="planned_day"><value>15</value></field>
    <field name="planned_month"><value>04</value></field>
    <field name="planned_year"><value>26</value></field>
    <field name="planned_direction"><value>Hinfahrt</value></field>
    <field name="planned_departure_station"><value>Teststadt Hbf</value></field>
    <field name="planned_departure_hours"><value>08</value></field>
    <field name="planned_departure_minutes"><value>04</value></field>
    <field name="planned_destination_station"><value>Beispielstadt Hbf</value></field>
    <field name="planned_destination_hours"><value>12</value></field>
    <field name="planned_destination_minutes"><value>10</value></field>
    <field name="arrived_day"><value>15</value></field>
    <field name="arrived_month"><value>04</value></field>
    <field name="arrived_year"><value>26</value></field>
    <field name="arrived_hours"><value>13</value></field>
    <field name="arrived_minutes"><value>24</value></field>
    <field name="ticket_digital"><value>Ja</value></field>
    <field name="ticket_digital_number"><value>000000000001</value></field>
    <field name="compensation"><value>Geldauszahlung/Überweisung</value></field>
    <field name="compensation_accountholder"><value>Erika Beispiel</value></field>
    <field name="compensation_iban"><value>DE00000000000000000000</value></field>
    <field name="compensation_bic"><value>SYNTHXXX</value></field>
    <field name="personal"><value>Frau</value></field>
    <field name="personal_firstname"><value>Erika</value></field>
    <field name="personal_lastname"><value>Beispiel</value></field>
    <field name="personal_street"><value>Testweg</value></field>
    <field name="personal_housenumber"><value>1</value></field>
    <field name="personal_postcode"><value>00000</value></field>
    <field name="personal_city"><value>Teststadt</value></field>
    <field name="date"><value>27.07.2026</value></field>
  </fields>
</xfdf>
XFDF

timeout 30 pdftk \
  "${FORM_PATH}" \
  fill_form "${XFDF_PATH}" \
  output "${FILLED_FORM_PATH}" \
  replacement_font "${FONT_PATH}"
FILLED_FIELD_DUMP="$(timeout 10 pdftk "${FILLED_FORM_PATH}" dump_data_fields_utf8)"

for expected_value in \
  "FieldValue: Erika Beispiel" \
  "FieldValue: DE00000000000000000000" \
  "FieldValue: 000000000001"; do
  if [[ "${FILLED_FIELD_DUMP}" != *"${expected_value}"* ]]; then
    echo "filled form missed: ${expected_value}" >&2
    exit 1
  fi
done

timeout 10 qpdf --check "${FILLED_FORM_PATH}" >/dev/null
timeout 30 qpdf \
  "${FILLED_FORM_PATH}" \
  "${FLATTENED_FORM_PATH}" \
  --generate-appearances \
  --flatten-annotations=all
timeout 10 qpdf --check "${FLATTENED_FORM_PATH}" >/dev/null
timeout 15 pdftoppm -f 2 -l 2 -singlefile -png -r 72 \
  "${FORM_PATH}" \
  "${WORK_DIR}/blank-form-page"
timeout 15 pdftoppm -f 2 -l 2 -singlefile -png -r 72 \
  "${FLATTENED_FORM_PATH}" \
  "${WORK_DIR}/filled-form-page"

if cmp -s "${WORK_DIR}/blank-form-page.png" "${WORK_DIR}/filled-form-page.png"; then
  echo "flattened form has no visible changes" >&2
  exit 1
fi
timeout 30 pdftocairo -pdf "${FLATTENED_FORM_PATH}" "${SANITIZED_FORM_PATH}"
timeout 30 pdftocairo -pdf "${TICKET_PATH}" "${SANITIZED_TICKET_PATH}"
timeout 30 pdftocairo -pdf "${INVOICE_PATH}" "${SANITIZED_INVOICE_PATH}"

timeout 30 qpdf \
  --empty \
  --pages "${SANITIZED_FORM_PATH}" "${SANITIZED_TICKET_PATH}" "${SANITIZED_INVOICE_PATH}" \
  -- \
  "${BUNDLE_PATH}"
timeout 10 qpdf --check "${BUNDLE_PATH}" >/dev/null

page_count="$(
  timeout 10 pdfinfo "${BUNDLE_PATH}" |
    awk '/^Pages:/ {print $2}'
)"

if [[ "${page_count}" != "4" ]]; then
  echo "unexpected bundle page count: ${page_count}" >&2
  exit 1
fi

timeout 15 pdftotext -layout -enc UTF-8 "${TICKET_PATH}" "${TICKET_TEXT_PATH}"

for expected_text in \
  "SYNTHETISCHES TESTTICKET" \
  "Auftragsnummer: 000000000001" \
  "Von: Teststadt Hbf" \
  "Nach: Beispielstadt Hbf" \
  "Fahrpreis: 129,90 EUR"; do
  if ! grep -Fq "${expected_text}" "${TICKET_TEXT_PATH}"; then
    echo "ticket text extraction missed: ${expected_text}" >&2
    exit 1
  fi
done

timeout 15 pdftotext -layout -enc UTF-8 "${BUNDLE_PATH}" "${BUNDLE_TEXT_PATH}"

for expected_text in \
  "SYNTHETISCHES TESTTICKET" \
  "SYNTHETISCHE RECHNUNG"; do
  if ! grep -Fq "${expected_text}" "${BUNDLE_TEXT_PATH}"; then
    echo "bundle text missed: ${expected_text}" >&2
    exit 1
  fi
done

if [[ -n "$(timeout 10 pdftk "${BUNDLE_PATH}" dump_data_fields_utf8)" ]]; then
  echo "bundle still contains AcroForm fields" >&2
  exit 1
fi

timeout 10 qpdf \
  --qdf \
  --object-streams=disable \
  "${BUNDLE_PATH}" \
  "${BUNDLE_QDF_PATH}"
strings "${BUNDLE_QDF_PATH}" >"${BUNDLE_STRINGS_PATH}"

if grep -Eq '/(AcroForm|JavaScript|OpenAction|EmbeddedFiles)' "${BUNDLE_STRINGS_PATH}"; then
  echo "bundle still contains active document-level content" >&2
  exit 1
fi

if [[ -n "${C00_OUTPUT_DIR:-}" ]]; then
  install -d -m 0700 "${C00_OUTPUT_DIR}"
  install -m 0600 "${SANITIZED_FORM_PATH}" "${C00_OUTPUT_DIR}/filled-form.pdf"
  install -m 0600 "${BUNDLE_PATH}" "${C00_OUTPUT_DIR}/bundle.pdf"
  install -m 0600 "${BUNDLE_TEXT_PATH}" "${C00_OUTPUT_DIR}/bundle.txt"
fi

echo "C00 PDF spike passed: text extracted, form filled, 4 A4 pages merged, active content removed"
