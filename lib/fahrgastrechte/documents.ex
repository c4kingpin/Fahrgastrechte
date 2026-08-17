defmodule Fahrgastrechte.Documents do
  @moduledoc """
  Scoped metadata and private storage for original and generated PDFs.

  Storage paths and keys never cross this context boundary. Callers receive a
  lazy byte stream only after ownership has been checked with `current_scope`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Changeset
  alias Fahrgastrechte.Accounts.Scope
  alias Fahrgastrechte.Accounts.User
  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Documents.Document
  alias Fahrgastrechte.Documents.LocalStorage
  alias Fahrgastrechte.Documents.PDFInspector
  alias Fahrgastrechte.Repo

  @generated_kinds [:generated_cover, :generated_form, :generated_bundle]

  @type upload :: %{
          required(:path) => Path.t(),
          required(:original_filename) => String.t(),
          required(:content_type) => String.t()
        }

  @type domain_error ::
          :not_authenticated
          | :not_found
          | :not_editable
          | :stale
          | :invalid_kind
          | :invalid_upload
          | :invalid_pdf
          | :wrong_content_type
          | :file_too_large
          | :too_many_pages
          | :timeout
          | :storage_unavailable

  @doc """
  Stores or replaces the current document of one kind.

  The new file is durable before the database transaction starts. Replacing an
  original marks the previous row non-current in that transaction and removes
  its file only after commit. Any current output is invalidated atomically.
  """
  @spec put_document(Scope.t(), Ecto.UUID.t(), Document.kind(), upload(), pos_integer()) ::
          {:ok, %{document: Document.t(), claim: Claims.Claim.t()}}
          | {:error, Changeset.t() | domain_error()}
  def put_document(%Scope{} = scope, claim_id, kind, upload, expected_claim_lock_version)
      when is_map(upload) do
    with {:ok, parsed_kind} <- parse_kind(kind),
         {:ok, normalized_upload} <- normalize_upload(upload),
         :ok <- validate_content_type(normalized_upload.content_type),
         :ok <- validate_pdf_signature(normalized_upload.path),
         :ok <- validate_source_size(normalized_upload.path),
         {:ok, inspection} <- PDFInspector.inspect(normalized_upload.path),
         {:ok, stored_file} <-
           LocalStorage.put(normalized_upload.path, documents_config(:max_file_size_bytes)) do
      persist_document(
        scope,
        claim_id,
        parsed_kind,
        normalized_upload,
        inspection,
        stored_file,
        expected_claim_lock_version
      )
    end
  end

  def put_document(_scope, _claim_id, _kind, _upload, _expected_claim_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Atomically publishes one complete generated export set.

  Files are validated and durably staged before the database transaction. The
  callback runs inside that transaction and can persist the owning C05 export
  version and transition the claim. A rollback removes every newly staged file;
  previous generated versions remain available as immutable history.
  """
  def commit_generated_set(
        %Scope{} = scope,
        claim_id,
        uploads,
        expected_claim_lock_version,
        callback
      )
      when is_map(uploads) and is_function(callback, 1) do
    with :ok <- validate_generated_kinds(uploads),
         {:ok, prepared} <- prepare_generated_uploads(uploads) do
      case Repo.transaction(fn ->
             with {:ok, claim} <- Claims.get_claim(scope, claim_id),
                  :ok <- verify_claim_lock(claim, expected_claim_lock_version),
                  {:ok, documents} <- persist_generated_set(scope, claim_id, prepared),
                  {:ok, callback_result} <- callback.(documents) do
               %{documents: documents, result: callback_result}
             else
               {:error, reason} -> Repo.rollback(reason)
               other -> Repo.rollback({:invalid_callback_result, other})
             end
           end) do
        {:ok, committed} ->
          {:ok, committed}

        {:error, reason} ->
          cleanup_prepared(prepared)
          normalize_transaction_error(reason)
      end
    end
  end

  def commit_generated_set(_scope, _claim_id, _uploads, _expected_lock_version, _callback),
    do: {:error, :not_authenticated}

  @doc "Returns one non-deleting document only when it belongs to the current user."
  @spec get_document(Scope.t(), Ecto.UUID.t()) ::
          {:ok, Document.t()} | {:error, domain_error()}
  def get_document(%Scope{user: %User{id: user_id}}, document_id) when is_binary(document_id) do
    with {:ok, parsed_id} <- Ecto.UUID.cast(document_id),
         %Document{} = document <-
           Repo.one(
             from document in Document,
               where:
                 document.id == ^parsed_id and document.user_id == ^user_id and
                   is_nil(document.deletion_pending_at)
           ) do
      {:ok, document}
    else
      _error -> {:error, :not_found}
    end
  end

  def get_document(%Scope{}, _document_id), do: {:error, :not_found}
  def get_document(_scope, _document_id), do: {:error, :not_authenticated}

  defp get_current_claim_document(
         %Scope{user: %User{id: user_id}} = scope,
         claim_id,
         document_id
       ) do
    with {:ok, _claim} <- Claims.get_claim(scope, claim_id),
         {:ok, parsed_id} <- Ecto.UUID.cast(document_id),
         %Document{} = document <-
           Repo.one(
             from document in Document,
               where:
                 document.id == ^parsed_id and document.claim_id == ^claim_id and
                   document.user_id == ^user_id and document.current == true and
                   is_nil(document.deletion_pending_at)
           ) do
      {:ok, document}
    else
      _error -> {:error, :not_found}
    end
  end

  @doc "Lists the current user's active documents for one scoped claim."
  @spec list_documents(Scope.t(), Ecto.UUID.t()) ::
          {:ok, [Document.t()]} | {:error, domain_error()}
  def list_documents(%Scope{user: %User{id: user_id}} = scope, claim_id) do
    with {:ok, _claim} <- Claims.get_claim(scope, claim_id) do
      documents =
        Repo.all(
          from document in Document,
            where:
              document.claim_id == ^claim_id and document.user_id == ^user_id and
                document.current == true and is_nil(document.deletion_pending_at),
            order_by: [asc: document.kind]
        )

      {:ok, documents}
    end
  end

  def list_documents(_scope, _claim_id), do: {:error, :not_authenticated}

  @doc "Returns authorized download metadata and a lazy binary stream."
  @spec stream_document(Scope.t(), Ecto.UUID.t()) ::
          {:ok, %{document: Document.t(), stream: Enumerable.t()}} | {:error, domain_error()}
  def stream_document(%Scope{} = scope, document_id) do
    with {:ok, document} <- get_document(scope, document_id),
         {:ok, stream} <- LocalStorage.stream(document.storage_key) do
      {:ok, %{document: document, stream: stream}}
    end
  end

  def stream_document(_scope, _document_id), do: {:error, :not_authenticated}

  @doc false
  @spec with_document_path(
          Scope.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          (Path.t(), Document.t() -> result)
        ) ::
          result | {:error, domain_error()}
        when result: term()
  def with_document_path(%Scope{} = scope, claim_id, document_id, callback)
      when is_function(callback, 2) do
    with {:ok, document} <- get_current_claim_document(scope, claim_id, document_id) do
      LocalStorage.with_path(document.storage_key, &callback.(&1, document))
    end
  end

  def with_document_path(_scope, _claim_id, _document_id, _callback),
    do: {:error, :not_authenticated}

  @doc """
  Idempotently deletes one scoped document and invalidates any current output.

  A pending marker makes a failed physical deletion retryable without exposing
  the half-deleted document to lists or downloads.
  """
  @spec delete_document(Scope.t(), Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Claims.Claim.t() | :already_deleted}
          | {:error, Changeset.t() | domain_error()}
  def delete_document(
        %Scope{user: %User{id: user_id}} = scope,
        claim_id,
        document_id,
        expected_lock_version
      )
      when is_binary(document_id) do
    with {:ok, _claim} <- Claims.get_claim(scope, claim_id) do
      case get_any_scoped_document(user_id, document_id) do
        nil ->
          {:ok, :already_deleted}

        %Document{claim_id: document_claim_id} when document_claim_id != claim_id ->
          {:error, :not_found}

        %Document{deletion_pending_at: pending_at} = document when not is_nil(pending_at) ->
          finalize_document_deletion(document, :already_deleted)

        %Document{} = document ->
          mark_and_delete_document(scope, document, expected_lock_version)
      end
    end
  end

  def delete_document(_scope, _claim_id, _document_id, _expected_lock_version),
    do: {:error, :not_authenticated}

  @doc """
  Coordinates final claim deletion with all private files owned by C03.

  Marking the claim `deleting` (`Claims.mark_deleting/3`) closes the race
  between the lock check and the final removal: once marked, the claim is
  invisible to every other mutation path, so the file removal below can
  never be followed by a stale conflict on the claim row itself. File
  removal is idempotent; a crash after marking is finished later by
  `cleanup_pending_claim_deletions/0`.
  """
  @spec delete_claim(Scope.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, Claims.Claim.t()} | {:error, Changeset.t() | domain_error()}
  def delete_claim(%Scope{} = scope, claim_id, expected_lock_version) do
    with {:ok, marked_claim} <- Claims.mark_deleting(scope, claim_id, expected_lock_version),
         {:ok, pending_documents} <-
           mark_claim_documents_pending(marked_claim.user_id, claim_id),
         :ok <- delete_files(pending_documents),
         :ok <- Claims.finalize_deletion(claim_id) do
      {:ok, marked_claim}
    end
  end

  def delete_claim(_scope, _claim_id, _expected_lock_version),
    do: {:error, :not_authenticated}

  defp persist_document(
         scope,
         claim_id,
         kind,
         upload,
         inspection,
         stored_file,
         expected_claim_lock_version
       ) do
    result =
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, claim_id, expected_claim_lock_version),
             {:ok, replaced_document} <- retire_current_document(scope, claim_id, kind),
             {:ok, document} <-
               insert_document(scope, claim_id, kind, upload, inspection, stored_file) do
          %{document: document, claim: claim, replaced_document: replaced_document}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{document: document, claim: claim, replaced_document: replaced_document}} ->
        cleanup_replaced_original(replaced_document)
        {:ok, %{document: document, claim: claim}}

      {:error, reason} ->
        _ = LocalStorage.delete(stored_file.storage_key)
        normalize_transaction_error(reason)
    end
  end

  defp retire_current_document(%Scope{user: %User{id: user_id}}, claim_id, kind) do
    document =
      Repo.one(
        from document in Document,
          where:
            document.claim_id == ^claim_id and document.user_id == ^user_id and
              document.kind == ^kind and document.current == true,
          lock: "FOR UPDATE"
      )

    case document do
      nil ->
        {:ok, nil}

      %Document{kind: original_kind} = current
      when original_kind in [:ticket, :invoice] ->
        current
        |> Document.replacement_changeset(now())
        |> Repo.update()

      %Document{} = current ->
        current
        |> Changeset.change(current: false)
        |> Repo.update()
    end
  end

  defp insert_document(
         %Scope{user: %User{id: user_id}},
         claim_id,
         kind,
         upload,
         inspection,
         stored_file
       ) do
    attrs = %{
      kind: kind,
      original_filename: upload.original_filename,
      storage_key: stored_file.storage_key,
      size_bytes: stored_file.size_bytes,
      page_count: inspection.page_count,
      sha256: stored_file.sha256,
      mime_type: "application/pdf",
      encrypted: inspection.encrypted,
      current: true
    }

    %Document{claim_id: claim_id, user_id: user_id}
    |> Document.create_changeset(attrs)
    |> Repo.insert()
  end

  defp validate_generated_kinds(uploads) do
    if uploads |> Map.keys() |> MapSet.new() == MapSet.new(@generated_kinds),
      do: :ok,
      else: {:error, :invalid_kind}
  end

  defp prepare_generated_uploads(uploads) do
    Enum.reduce_while(@generated_kinds, {:ok, %{}}, fn kind, {:ok, prepared} ->
      upload = Map.fetch!(uploads, kind)

      result =
        with {:ok, normalized_upload} <- normalize_upload(upload),
             :ok <- validate_content_type(normalized_upload.content_type),
             :ok <- validate_pdf_signature(normalized_upload.path),
             :ok <- validate_source_size(normalized_upload.path),
             {:ok, inspection} <- PDFInspector.inspect(normalized_upload.path),
             {:ok, stored_file} <-
               LocalStorage.put(normalized_upload.path, documents_config(:max_file_size_bytes)) do
          {:ok,
           %{
             upload: normalized_upload,
             inspection: inspection,
             stored_file: stored_file
           }}
        end

      case result do
        {:ok, item} ->
          {:cont, {:ok, Map.put(prepared, kind, item)}}

        {:error, reason} ->
          cleanup_prepared(prepared)
          {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_generated_set(scope, claim_id, prepared) do
    Enum.reduce_while(@generated_kinds, {:ok, %{}}, fn kind, {:ok, documents} ->
      item = Map.fetch!(prepared, kind)

      with {:ok, _previous} <- retire_current_document(scope, claim_id, kind),
           {:ok, document} <-
             insert_document(
               scope,
               claim_id,
               kind,
               item.upload,
               item.inspection,
               item.stored_file
             ) do
        {:cont, {:ok, Map.put(documents, kind, document)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_prepared(prepared) do
    Enum.each(prepared, fn {_kind, item} ->
      _ = LocalStorage.delete(item.stored_file.storage_key)
    end)

    :ok
  end

  defp cleanup_replaced_original(nil), do: :ok
  defp cleanup_replaced_original(%Document{deletion_pending_at: nil}), do: :ok

  defp cleanup_replaced_original(%Document{} = document) do
    case LocalStorage.delete(document.storage_key) do
      :ok ->
        case Repo.delete(document) do
          {:ok, _deleted} -> :ok
          {:error, _changeset} -> log_cleanup_retry(document.id)
        end

      {:error, _reason} ->
        log_cleanup_retry(document.id)
    end
  end

  defp mark_and_delete_document(scope, document, expected_lock_version) do
    result =
      Repo.transaction(fn ->
        with {:ok, claim} <-
               Claims.invalidate_output(scope, document.claim_id, expected_lock_version),
             {:ok, pending_document} <-
               document |> Document.deletion_changeset(now()) |> Repo.update() do
          %{claim: claim, document: pending_document}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{claim: claim, document: pending_document}} ->
        finalize_document_deletion(pending_document, claim)

      {:error, reason} ->
        normalize_transaction_error(reason)
    end
  end

  defp finalize_document_deletion(document, success_value) do
    with :ok <- LocalStorage.delete(document.storage_key),
         {:ok, _deleted} <- Repo.delete(document) do
      {:ok, success_value}
    else
      {:error, %Changeset{} = changeset} -> {:error, changeset}
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  defp get_any_scoped_document(user_id, document_id) do
    case Ecto.UUID.cast(document_id) do
      {:ok, parsed_id} ->
        Repo.one(
          from document in Document,
            where: document.id == ^parsed_id and document.user_id == ^user_id
        )

      :error ->
        nil
    end
  end

  defp all_claim_documents(user_id, claim_id) do
    Repo.all(
      from document in Document,
        where: document.claim_id == ^claim_id and document.user_id == ^user_id
    )
  end

  defp mark_claim_documents_pending(user_id, claim_id) do
    Repo.transaction(fn ->
      timestamp = now()

      all_claim_documents(user_id, claim_id)
      |> Enum.map(fn document ->
        case document |> Document.deletion_changeset(timestamp) |> Repo.update() do
          {:ok, pending_document} -> pending_document
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  @doc """
  Retries every physical deletion that a previous request could not complete.

  Deletion marks a row pending, removes the file and only then removes the row.
  If the file removal fails, the row stays pending and invisible to lists and
  downloads. This sweep is the retry for those rows. It is maintenance on data
  the system owns rather than a user request, so it runs on a schedule instead
  of inside a read path — see `Fahrgastrechte.Documents.CleanupWorker`.
  """
  @spec cleanup_pending_documents() :: {:ok, non_neg_integer()}
  def cleanup_pending_documents do
    pending =
      Repo.all(from document in Document, where: not is_nil(document.deletion_pending_at))

    Enum.each(pending, &cleanup_replaced_original/1)

    {:ok, length(pending)}
  end

  @doc """
  Finishes any claim deletion left in the `deleting` state by a crash between
  marking it (`Claims.mark_deleting/3`) and completing physical file and
  database removal. Mirrors `cleanup_pending_documents/0`.
  """
  @spec cleanup_pending_claim_deletions() :: {:ok, non_neg_integer()}
  def cleanup_pending_claim_deletions do
    pending = Claims.list_pending_deletions()

    Enum.each(pending, fn claim ->
      with {:ok, pending_documents} <- mark_claim_documents_pending(claim.user_id, claim.id),
           :ok <- delete_files(pending_documents) do
        Claims.finalize_deletion(claim.id)
      end
    end)

    {:ok, length(pending)}
  end

  defp delete_files(documents) do
    Enum.reduce_while(documents, :ok, fn document, :ok ->
      case LocalStorage.delete(document.storage_key) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :storage_unavailable}}
      end
    end)
  end

  defp verify_claim_lock(%{lock_version: version}, version), do: :ok
  defp verify_claim_lock(_claim, _expected_lock_version), do: {:error, :stale}

  defp normalize_upload(upload) do
    path = value(upload, :path)
    filename = value(upload, :original_filename)
    content_type = value(upload, :content_type)

    if is_binary(path) and is_binary(filename) and is_binary(content_type) do
      {:ok,
       %{
         path: path,
         original_filename: sanitize_filename(filename),
         content_type: String.downcase(String.trim(content_type))
       }}
    else
      {:error, :invalid_upload}
    end
  end

  defp sanitize_filename(filename) do
    sanitized =
      filename
      |> String.replace("\\", "/")
      |> Path.basename()
      |> String.replace(~r/[[:cntrl:]]/u, "")
      |> String.trim()
      |> String.slice(0, 255)

    if sanitized == "", do: "document.pdf", else: sanitized
  end

  defp validate_content_type("application/pdf"), do: :ok
  defp validate_content_type(_content_type), do: {:error, :wrong_content_type}

  defp validate_pdf_signature(path) do
    case File.open(path, [:read, :binary], fn file -> IO.binread(file, 1024) end) do
      {:ok, data} when is_binary(data) ->
        if :binary.match(data, "%PDF-") == :nomatch,
          do: {:error, :invalid_pdf},
          else: :ok

      _error ->
        {:error, :invalid_upload}
    end
  end

  defp validate_source_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 ->
        if size <= documents_config(:max_file_size_bytes),
          do: :ok,
          else: {:error, :file_too_large}

      _error ->
        {:error, :invalid_upload}
    end
  end

  defp parse_kind(kind)
       when kind in [:ticket, :invoice, :generated_cover, :generated_form, :generated_bundle],
       do: {:ok, kind}

  defp parse_kind(kind) when is_binary(kind) do
    case Enum.find(Document.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> {:error, :invalid_kind}
      parsed -> {:ok, parsed}
    end
  end

  defp parse_kind(_kind), do: {:error, :invalid_kind}

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp documents_config(key) do
    :fahrgastrechte
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(key)
  end

  defp normalize_transaction_error(%Changeset{} = changeset), do: {:error, changeset}
  defp normalize_transaction_error(reason), do: {:error, reason}

  defp log_cleanup_retry(document_id) do
    Logger.warning("document cleanup remains pending", document_id: document_id)
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
