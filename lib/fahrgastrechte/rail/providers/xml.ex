defmodule Fahrgastrechte.Rail.Providers.XML do
  @moduledoc false

  def parse(document) when is_binary(document) do
    if String.contains?(String.upcase(document), ["<!DOCTYPE", "<!ENTITY"]) do
      {:error, :unsafe_xml}
    else
      try do
        # xmerl is a byte-oriented parser: it decodes multi-byte characters
        # itself based on the document's declared encoding. Feeding it
        # `String.to_charlist/1` (already-decoded Unicode codepoints) instead
        # of raw bytes makes it misread any non-ASCII byte (e.g. "ü", "ß" in
        # German station names) as an illegal character.
        {root, _rest} =
          document
          |> :binary.bin_to_list()
          |> :xmerl_scan.string(quiet: true)

        {:ok, root}
      rescue
        _error -> {:error, :invalid_xml}
      catch
        :exit, _reason -> {:error, :invalid_xml}
      end
    end
  end

  def elements(root, path) do
    path
    |> String.to_charlist()
    |> :xmerl_xpath.string(root)
  end

  def attr(element, name) when is_atom(name) do
    element
    |> elem(7)
    |> Enum.find_value(fn attribute ->
      if elem(attribute, 1) == name, do: attribute |> elem(8) |> List.to_string()
    end)
  end

  @doc """
  Concatenates an element's own text, ignoring nested child elements.

  Namespaced formats like NeTEx nest further elements inside a name (e.g.
  `<Name lang="de">Flensburg<Text lang="dan">Flensborg</Text></Name>`); only
  the direct `xmlText` content nodes belong to the element itself.
  """
  def text(nil), do: nil

  def text(element) do
    element
    |> elem(8)
    |> Enum.filter(&(elem(&1, 0) == :xmlText))
    |> Enum.map_join("", &(&1 |> elem(4) |> List.to_string()))
    |> String.trim()
  end
end
