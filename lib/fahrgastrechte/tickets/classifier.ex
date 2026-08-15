defmodule Fahrgastrechte.Tickets.Classifier do
  @moduledoc """
  Guesses whether extracted PDF text belongs to a ticket or an invoice.

  Scoring only, never blocking: an ambiguous result lets the caller fall back
  to whichever document kind the claim is still missing.
  """

  @ticket_markers [
    ~r/Fahrpreis:/u,
    ~r/Gesamtpreis/u,
    ~r/Reiseplan/u,
    ~r/^Von:/mu,
    ~r/^Nach:/mu
  ]

  @invoice_markers [
    ~r/Gesamtbetrag:/u,
    ~r/Summe\s+\(brutto\)/u,
    ~r/Rechnungsnummer/u,
    ~r/Rechnungsdatum/u,
    ~r/Leistungsdatum:/u
  ]

  @doc "Classifies extracted document text as `:ticket` or `:invoice` with a confidence score."
  @spec classify(String.t()) :: {:ok, :ticket | :invoice, float()} | {:error, :ambiguous}
  def classify(text) when is_binary(text) do
    ticket_score = count_matches(text, @ticket_markers)
    invoice_score = count_matches(text, @invoice_markers)

    cond do
      ticket_score == invoice_score -> {:error, :ambiguous}
      ticket_score > invoice_score -> {:ok, :ticket, confidence(ticket_score, invoice_score)}
      true -> {:ok, :invoice, confidence(invoice_score, ticket_score)}
    end
  end

  defp count_matches(text, patterns), do: Enum.count(patterns, &Regex.match?(&1, text))

  defp confidence(winner, loser), do: Float.round(winner / (winner + loser), 2)
end
