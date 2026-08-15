defmodule FahrgastrechteWeb.ClaimLive.PayoutFormTest do
  use FahrgastrechteWeb.ConnCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Phoenix.LiveViewTest

  alias Fahrgastrechte.Accounts
  alias Fahrgastrechte.Accounts.Scope
  alias FahrgastrechteWeb.UserAuth

  test "completes the payout profile inline on the review step without leaving the claim", %{
    conn: conn
  } do
    {conn, scope} = authenticated_conn(conn)
    claim = claim_fixture(scope)
    {:ok, view, _html} = live(conn, ~p"/antraege/#{claim.id}/pruefung")

    assert has_element?(view, "#payout-form-section")
    assert has_element?(view, "#payout-country[value='Deutschland']")
    refute has_element?(view, "#profile-back-to-claim")

    view
    |> form("#payout-form",
      profile: %{
        "salutation" => "neutral",
        "first_name" => "Erika",
        "last_name" => "Beispiel",
        "street" => "Testweg",
        "house_number" => "1",
        "postal_code" => "10115",
        "city" => "Berlin",
        "country" => "Deutschland",
        "iban" => "DE89370400440532013000",
        "bic" => "COBADEFFXXX"
      }
    )
    |> render_submit()

    assert {:ok, profile} = Accounts.get_profile(scope)
    assert profile.account_holder == "Erika Beispiel"
    assert Accounts.profile_complete?(profile)

    refute has_element?(view, "#payout-form-section")
    assert has_element?(view, "#review-checklist", "Bestätigt")
  end

  defp authenticated_conn(conn) do
    user = user_fixture()
    scope = Scope.for_user(user)
    conn = conn |> init_test_session(%{}) |> UserAuth.log_in_user(user)
    {conn, scope}
  end
end
