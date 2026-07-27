defmodule Fahrgastrechte.Tickets.Extractor do
  @moduledoc """
  Contract for extracting text and suggestions from ticket-like PDFs.

  Extractors never confirm values. Every proposal retains its source location
  and confidence so the caller can present it as an editable suggestion.
  """

  @type extraction :: %{
          required(:text) => String.t(),
          required(:pages) => pos_integer(),
          optional(:metadata) => map()
        }

  @type source_location :: %{
          required(:page) => pos_integer(),
          optional(:excerpt) => String.t(),
          optional(:bounding_box) => {number(), number(), number(), number()}
        }

  @type suggestion :: %{
          required(:field) => atom(),
          required(:value) => term(),
          required(:confidence) => float(),
          required(:source) => source_location()
        }

  @type extraction_error ::
          :encrypted
          | :invalid_pdf
          | :no_text
          | :resource_limit
          | :timeout
          | {:backend, term()}

  @doc "Extracts UTF-8 text and page metadata without performing OCR."
  @callback extract(pdf_path :: String.t(), options :: keyword()) ::
              {:ok, extraction()} | {:error, extraction_error()}

  @doc "Builds unconfirmed, traceable field suggestions from extracted text."
  @callback propose(extraction :: extraction(), options :: keyword()) ::
              {:ok, [suggestion()]} | {:error, extraction_error()}
end
