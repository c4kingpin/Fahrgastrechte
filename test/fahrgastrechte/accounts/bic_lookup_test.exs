defmodule Fahrgastrechte.Accounts.BicLookupTest do
  use ExUnit.Case, async: true

  alias Fahrgastrechte.Accounts.BicLookup

  test "derives the BIC from the bank code of a known German IBAN" do
    assert {:ok, "COBADEFFXXX"} = BicLookup.derive("DE89370400440532013000")
  end

  test "ignores spacing and casing" do
    assert {:ok, "INGDDEFFXXX"} = BicLookup.derive("de12 5001 0517 0000 0000 01")
  end

  test "admits it cannot derive a BIC for an unlisted bank code" do
    assert :unknown = BicLookup.derive("DE02100500000054540402")
  end

  test "refuses non-German and malformed IBANs" do
    assert :unknown = BicLookup.derive("AT611904300234573201")
    assert :unknown = BicLookup.derive("DE89")
    assert :unknown = BicLookup.derive("")
    assert :unknown = BicLookup.derive(nil)
  end
end
