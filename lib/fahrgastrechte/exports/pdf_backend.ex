defmodule Fahrgastrechte.Exports.PDFBackend do
  @moduledoc """
  Contract for the isolated PDF worker used by documents and exports.

  Implementations must write outputs atomically, enforce the supplied limits
  and avoid logging document contents or field values.
  """

  @type pdf_info :: %{
          required(:pages) => pos_integer(),
          required(:bytes) => non_neg_integer(),
          required(:page_sizes) => [{number(), number()}],
          optional(:encrypted) => boolean()
        }

  @type field_value :: {String.t(), String.t()}

  @type backend_error ::
          :encrypted
          | :invalid_pdf
          | :missing_field
          | :resource_limit
          | :timeout
          | {:command_failed, String.t()}

  @doc "Validates structure, size and page limits without modifying the input."
  @callback validate(pdf_path :: String.t(), options :: keyword()) ::
              {:ok, pdf_info()} | {:error, backend_error()}

  @doc "Extracts UTF-8 text from a validated PDF."
  @callback extract_text(pdf_path :: String.t(), options :: keyword()) ::
              {:ok, String.t()} | {:error, backend_error()}

  @doc "Fills known AcroForm fields before the separate normalization step."
  @callback fill_form(
              template_path :: String.t(),
              fields :: [field_value()],
              output_path :: String.t(),
              options :: keyword()
            ) :: :ok | {:error, backend_error()}

  @doc "Flattens annotations and removes document-level active content."
  @callback normalize(
              input_path :: String.t(),
              output_path :: String.t(),
              options :: keyword()
            ) :: :ok | {:error, backend_error()}

  @doc "Merges normalized inputs in order into one new PDF document."
  @callback merge(
              input_paths :: [String.t()],
              output_path :: String.t(),
              options :: keyword()
            ) :: :ok | {:error, backend_error()}
end
