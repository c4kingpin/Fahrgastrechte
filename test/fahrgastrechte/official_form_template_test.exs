defmodule Fahrgastrechte.OfficialFormTemplateTest do
  use ExUnit.Case, async: true

  @template_name "fahrgastrechte-2025-me-08-25"

  test "ships the verified official form alongside its manifest" do
    template_dir = Application.app_dir(:fahrgastrechte, "priv/form_templates")
    template_path = Path.join(template_dir, "#{@template_name}.pdf")
    manifest_path = Path.join(template_dir, "#{@template_name}.json")

    manifest = manifest_path |> File.read!() |> Jason.decode!()
    actual_sha256 = template_path |> File.read!() |> then(&:crypto.hash(:sha256, &1))

    assert File.regular?(template_path)
    assert Base.encode16(actual_sha256, case: :lower) == manifest["sha256"]
  end
end
