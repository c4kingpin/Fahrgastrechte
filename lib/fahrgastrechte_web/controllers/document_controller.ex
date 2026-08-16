defmodule FahrgastrechteWeb.DocumentController do
  use FahrgastrechteWeb, :controller

  alias Fahrgastrechte.Documents

  def download(conn, %{"id" => document_id}) do
    case Documents.stream_document(conn.assigns.current_scope, document_id) do
      {:ok, %{document: document, stream: stream}} ->
        conn =
          conn
          # Only PDFs are ever stored, so the type is fixed here rather than
          # echoed back from a database column.
          |> put_resp_content_type("application/pdf")
          |> put_resp_header(
            "content-disposition",
            content_disposition(document.original_filename)
          )
          |> put_resp_header("cache-control", "private, no-store")
          |> put_resp_header("x-content-type-options", "nosniff")
          # A chunked response must not carry Content-Length (RFC 9112 §6.2);
          # proxies may otherwise truncate or drop it.
          |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
          |> send_chunked(200)

        Enum.reduce_while(stream, conn, fn bytes, current_conn ->
          case chunk(current_conn, bytes) do
            {:ok, next_conn} -> {:cont, next_conn}
            {:error, _reason} -> {:halt, current_conn}
          end
        end)

      {:error, :not_found} ->
        send_resp(conn, 404, "Nicht gefunden")

      {:error, _reason} ->
        send_resp(conn, 503, "Dokument derzeit nicht verfügbar")
    end
  end

  defp content_disposition(filename) do
    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    "attachment; filename*=UTF-8''#{encoded}"
  end
end
