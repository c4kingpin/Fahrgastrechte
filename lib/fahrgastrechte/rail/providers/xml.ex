defmodule Fahrgastrechte.Rail.Providers.XML do
  @moduledoc false

  def parse(document) when is_binary(document) do
    if String.contains?(String.upcase(document), ["<!DOCTYPE", "<!ENTITY"]) do
      {:error, :unsafe_xml}
    else
      try do
        {root, _rest} =
          document
          |> String.to_charlist()
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
end
