defmodule Fahrgastrechte.Exports do
  @moduledoc """
  Versioned, user-scoped creation of print-ready passenger-rights PDFs.

  Export generation reads dependent data exclusively through the Accounts,
  Claims, Documents and Rail contexts. Rendering happens in a private temporary
  directory; publishing all generated documents, the immutable version row and
  the `ready` transition is one database transaction.
  """

  import Ecto.Query, warn: false

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents
  alias Fahrgastrechte.Exports.CoverRenderer
  alias Fahrgastrechte.Exports.ExportVersion
  alias Fahrgastrechte.Exports.Template
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Repo
  alias Fahrgastrechte.Tickets

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :not_editable
          | :stale
          | :template_unavailable
          | :template_changed
          | :render_failed
          | :invalid_pdf
          | :resource_limit
          | :timeout
          | {:command_failed, String.t()}
          | %{type: :incomplete, errors: [map()]}

  @doc "Builds and atomically publishes the next output version for one draft claim."
  @spec generate_export(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, %{export: ExportVersion.t(), claim: Claims.Claim.t()}}
          | {:error, Ecto.Changeset.t() | domain_error()}
  def generate_export(%Scope{} = scope, claim_id, expected_claim_lock_version) do
    :global.trans({__MODULE__, :pdf_job}, fn ->
      with {:ok, model} <- build_model(scope, claim_id, expected_claim_lock_version),
           {:ok, template} <- Template.current(),
           {:ok, work_dir} <- create_work_dir() do
        try do
          render_and_publish(scope, model, template, work_dir)
        after
          File.rm_rf(work_dir)
        end
      end
    end)
  end

  def generate_export(_scope, _claim_id, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  @doc "Returns all structured fach data errors needed by a later review page."
  @spec readiness(Scope.t(), Ecto.UUID.t()) :: {:ok, map()} | {:error, domain_error()}
  def readiness(%Scope{} = scope, claim_id) do
    with {:ok, _claim} <- Claims.get_claim(scope, claim_id) do
      [
        claim: Claims.export_readiness(scope, claim_id),
        profile: complete_profile(scope),
        rail: Rail.form_values(scope, claim_id),
        documents: required_documents(scope, claim_id)
      ]
      |> collect_readiness(scope)
    end
  end

  def readiness(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc "Lists immutable output versions oldest first for one scoped claim."
  @spec list_exports(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [ExportVersion.t()]} | {:error, domain_error()}
  def list_exports(%Scope{user: %User{id: user_id}} = scope, claim_id) do
    with {:ok, _claim} <- Claims.get_claim(scope, claim_id) do
      {:ok,
       Repo.all(
         from export in ExportVersion,
           where: export.claim_id == ^claim_id and export.user_id == ^user_id,
           order_by: [asc: export.version]
       )}
    end
  end

  def list_exports(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc "Loads one output version only for its owner."
  @spec get_export(Scope.t(), Ecto.UUID.t()) ::
          {:ok, ExportVersion.t()} | {:error, domain_error()}
  def get_export(%Scope{user: %User{id: user_id}}, export_id) when is_binary(export_id) do
    with {:ok, id} <- Ecto.UUID.cast(export_id),
         %ExportVersion{} = export <-
           Repo.one(
             from export in ExportVersion, where: export.id == ^id and export.user_id == ^user_id
           ) do
      {:ok, export}
    else
      _error -> {:error, :not_found}
    end
  end

  def get_export(%Scope{}, _export_id), do: {:error, :not_found}
  def get_export(_scope, _export_id), do: {:error, :not_authenticated}

  @doc "Returns the authorized download stream for a historical or current bundle."
  def stream_bundle(%Scope{} = scope, export_id) do
    with {:ok, export} <- get_export(scope, export_id) do
      Documents.stream_document(scope, export.bundle_document_id)
    end
  end

  def stream_bundle(_scope, _export_id), do: {:error, :not_authenticated}

  defp build_model(scope, claim_id, expected_lock_version) do
    with {:ok, prerequisites} <- readiness(scope, claim_id),
         :ok <- editable_claim(prerequisites.claim, expected_lock_version) do
      {:ok,
       %{
         claim: prerequisites.claim,
         profile: prerequisites.profile,
         rail: prerequisites.rail,
         ticket: prerequisites.documents.ticket,
         ticket_order_number: prerequisites.ticket_values.order_number,
         invoice: prerequisites.documents.invoice,
         created_on: Date.utc_today()
       }}
    end
  end

  defp collect_readiness(results, scope) do
    case Enum.reduce_while(results, {%{}, []}, fn
           {key, {:ok, value}}, {values, errors} ->
             {:cont, {Map.put(values, key, value), errors}}

           {_key, {:error, %{type: :incomplete, errors: readiness_errors}}}, {values, errors} ->
             {:cont, {values, errors ++ readiness_errors}}

           {_key, {:error, reason}}, _acc ->
             {:halt, {:error, reason}}
         end) do
      {:error, reason} ->
        {:error, reason}

      {_values, errors} when errors != [] ->
        {:error, %{type: :incomplete, errors: errors}}

      {values, []} ->
        with {:ok, ticket_values} <- accepted_ticket_values(scope, values.documents.ticket) do
          {:ok, Map.put(values, :ticket_values, ticket_values)}
        end
    end
  end

  defp editable_claim(%{status: :draft, lock_version: version}, version), do: :ok

  defp editable_claim(%{lock_version: version}, expected) when version != expected,
    do: {:error, :stale}

  defp editable_claim(_claim, _expected), do: {:error, :not_editable}

  defp complete_profile(scope) do
    with {:ok, completeness} <- Accounts.profile_completeness(scope) do
      if completeness.complete? do
        {:ok, completeness.profile}
      else
        {:error,
         %{
           type: :incomplete,
           errors:
             Enum.map(
               completeness.missing_fields,
               &%{source: :profile, field: &1, code: :required}
             )
         }}
      end
    end
  end

  defp required_documents(scope, claim_id) do
    with {:ok, documents} <- Documents.list_documents(scope, claim_id) do
      ticket = Enum.find(documents, &(&1.kind == :ticket))
      invoice = Enum.find(documents, &(&1.kind == :invoice))

      errors =
        []
        |> required_document_error(ticket, :ticket)
        |> required_document_error(invoice, :invoice)
        |> Enum.reverse()

      if errors == [],
        do: {:ok, %{ticket: ticket, invoice: invoice}},
        else: {:error, %{type: :incomplete, errors: errors}}
    end
  end

  defp required_document_error(errors, nil, kind),
    do: [%{source: :documents, field: kind, code: :required} | errors]

  defp required_document_error(errors, _document, _kind), do: errors

  defp accepted_ticket_values(scope, ticket) do
    with {:ok, suggestions} <- Tickets.list_suggestions(scope, ticket.id) do
      order_number =
        Enum.find_value(suggestions, fn
          %{field: :order_number, state: :accepted, value: %{"text" => value}} -> value
          _suggestion -> nil
        end)

      {:ok, %{order_number: order_number}}
    end
  end

  defp render_and_publish(scope, model, template, work_dir) do
    Documents.with_document_path(
      scope,
      model.claim.id,
      model.ticket.id,
      fn ticket_path, _ticket ->
        Documents.with_document_path(
          scope,
          model.claim.id,
          model.invoice.id,
          fn invoice_path, _invoice ->
            run_pipeline(scope, model, template, ticket_path, invoice_path, work_dir)
          end
        )
      end
    )
  end

  defp run_pipeline(scope, model, template, ticket_path, invoice_path, work_dir) do
    backend = exports_config(:backend)
    options = backend_options(template)
    paths = output_paths(work_dir)
    fields = form_fields(model)

    with :ok <- Template.validate_form_fields(template, fields),
         {:ok, template_info} <-
           backend.validate(template.path, Keyword.put(options, :template, true)),
         {:ok, ticket_info} <- backend.validate(ticket_path, options),
         {:ok, invoice_info} <- backend.validate(invoice_path, options),
         false <- template_info.encrypted || ticket_info.encrypted || invoice_info.encrypted,
         :ok <- CoverRenderer.render(model, paths.cover),
         {:ok, %{pages: 1}} <- backend.validate(paths.cover, options),
         :ok <- backend.fill_form(template.path, fields, paths.filled_form, options),
         :ok <- backend.normalize(paths.filled_form, paths.form, options),
         :ok <- backend.normalize(ticket_path, paths.ticket, options),
         :ok <- backend.normalize(invoice_path, paths.invoice, options),
         {:ok, form_info} <- backend.validate(paths.form, Keyword.put(options, :inactive, true)),
         {:ok, normalized_ticket_info} <-
           backend.validate(paths.ticket, Keyword.put(options, :inactive, true)),
         {:ok, normalized_invoice_info} <-
           backend.validate(paths.invoice, Keyword.put(options, :inactive, true)),
         :ok <-
           backend.merge(
             [paths.cover, paths.form, paths.ticket, paths.invoice],
             paths.bundle,
             options
           ),
         expected_pages =
           1 + form_info.pages + normalized_ticket_info.pages + normalized_invoice_info.pages,
         {:ok, %{pages: ^expected_pages}} <-
           backend.validate(paths.bundle, Keyword.put(options, :inactive, true)) do
      publish(scope, model, template, paths)
    else
      true -> {:error, :invalid_pdf}
      {:ok, _unexpected_info} -> {:error, :invalid_pdf}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish(scope, model, template, paths) do
    uploads = %{
      generated_cover: generated_upload(paths.cover, model, "deckblatt"),
      generated_form: generated_upload(paths.form, model, "formular"),
      generated_bundle: generated_upload(paths.bundle, model, "gesamt")
    }

    callback = fn documents -> persist_version(scope, model, template, documents) end

    case Documents.commit_generated_set(
           scope,
           model.claim.id,
           uploads,
           model.claim.lock_version,
           callback
         ) do
      {:ok, %{result: result}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_version(scope, model, template, documents) do
    next_version =
      Repo.one(
        from export in ExportVersion,
          where: export.claim_id == ^model.claim.id,
          select: coalesce(max(export.version), 0)
      ) + 1

    attrs = %{
      version: next_version,
      template_version: template.version,
      template_source: template.source,
      template_sha256: template.sha256,
      model_sha256: model_digest(model),
      cover_document_id: documents.generated_cover.id,
      form_document_id: documents.generated_form.id,
      bundle_document_id: documents.generated_bundle.id
    }

    with {:ok, export} <-
           %ExportVersion{claim_id: model.claim.id, user_id: model.claim.user_id}
           |> ExportVersion.create_changeset(attrs)
           |> Repo.insert(),
         {:ok, ready_claim} <-
           Claims.transition_claim(scope, model.claim.id, :ready, model.claim.lock_version) do
      {:ok, %{export: export, claim: ready_claim}}
    end
  end

  defp form_fields(model) do
    departure = model.rail.scheduled_departure
    arrival = model.rail.scheduled_arrival
    profile = model.profile

    [
      {"journey", journey_value(model.claim.journey_outcome)},
      {"planned_day", two(departure.day)},
      {"planned_month", two(departure.month)},
      {"planned_year", two(rem(departure.year, 100))},
      {"planned_direction", direction_value(model.claim.journey_direction)},
      {"planned_departure_station", model.claim.origin},
      {"planned_departure_hours", two(departure.hour)},
      {"planned_departure_minutes", two(departure.minute)},
      {"planned_destination_station", model.claim.destination},
      {"planned_destination_hours", two(arrival.hour)},
      {"planned_destination_minutes", two(arrival.minute)},
      {"ticket_digital", "Ja"},
      {"compensation", "Geldauszahlung/Überweisung"},
      {"compensation_accountholder", profile.account_holder},
      {"compensation_iban", profile.iban},
      {"compensation_bic", profile.bic},
      {"personal", salutation(profile.salutation)},
      {"personal_firstname", profile.first_name},
      {"personal_lastname", profile.last_name},
      {"personal_street", profile.street},
      {"personal_housenumber", profile.house_number},
      {"personal_postcode", profile.postal_code},
      {"personal_city", profile.city},
      {"date", Calendar.strftime(model.created_on, "%d.%m.%Y")}
    ]
    |> maybe_add_arrival(model.rail.actual_destination_arrival)
    |> maybe_add_ticket_order(model.ticket_order_number)
  end

  defp maybe_add_arrival(fields, nil), do: fields

  defp maybe_add_arrival(fields, arrival) do
    fields ++
      [
        {"arrived_day", two(arrival.day)},
        {"arrived_month", two(arrival.month)},
        {"arrived_year", two(rem(arrival.year, 100))},
        {"arrived_hours", two(arrival.hour)},
        {"arrived_minutes", two(arrival.minute)}
      ]
  end

  defp maybe_add_ticket_order(fields, nil), do: fields

  defp maybe_add_ticket_order(fields, order_number),
    do: fields ++ [{"ticket_digital_number", order_number}]

  defp journey_value(:delayed_arrival), do: "Verspätung am Ziel (mind. 60 Minuten)"

  defp journey_value(:not_started),
    do:
      "Reise nicht angetreten (Zugausfall oder erwartete Verspätung am Ziel von mind. 60 Minuten)"

  defp journey_value(:aborted),
    do: "Reise unterwegs abgebrochen und zurück zum Startbahnhof"

  defp journey_value(:continued_with_other_transport),
    do:
      "Reise unterbrochen und mit anderem Verkehrsmittel fortgesetzt, für das Zusatzkosten entstanden sind"

  defp direction_value(:outbound), do: "Hinfahrt"
  defp direction_value(:return), do: "Rückfahrt"

  defp salutation("female"), do: "Frau"
  defp salutation("male"), do: "Herr"
  defp salutation("neutral"), do: "Neutrale Anrede"

  defp two(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp model_digest(model) do
    model
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp generated_upload(path, model, label) do
    %{
      path: path,
      original_filename: "#{model.claim.claim_number}-#{label}.pdf",
      content_type: "application/pdf"
    }
  end

  defp output_paths(work_dir) do
    %{
      cover: Path.join(work_dir, "cover.pdf"),
      filled_form: Path.join(work_dir, "filled-form.pdf"),
      form: Path.join(work_dir, "form.pdf"),
      ticket: Path.join(work_dir, "ticket.pdf"),
      invoice: Path.join(work_dir, "invoice.pdf"),
      bundle: Path.join(work_dir, "bundle.pdf")
    }
  end

  defp create_work_dir do
    path = Path.join(System.tmp_dir!(), "fahrgastrechte-export-#{Ecto.UUID.generate()}")

    with :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    else
      _error -> {:error, :render_failed}
    end
  end

  defp backend_options(template) do
    config = Application.fetch_env!(:fahrgastrechte, __MODULE__)

    [
      timeout_ms: Keyword.fetch!(config, :command_timeout_ms),
      max_bytes: Keyword.fetch!(config, :max_file_size_bytes),
      max_pages: Keyword.fetch!(config, :max_page_count),
      qpdf: Keyword.fetch!(config, :qpdf_executable),
      pdfinfo: Keyword.fetch!(config, :pdfinfo_executable),
      pdftk: Keyword.fetch!(config, :pdftk_executable),
      pdftocairo: Keyword.fetch!(config, :pdftocairo_executable),
      font_path: Keyword.fetch!(config, :font_path),
      required_fields: template.required_fields
    ]
  end

  defp exports_config(key) do
    :fahrgastrechte |> Application.fetch_env!(__MODULE__) |> Keyword.fetch!(key)
  end
end
