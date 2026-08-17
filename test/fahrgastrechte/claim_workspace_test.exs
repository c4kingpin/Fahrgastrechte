defmodule Fahrgastrechte.ClaimWorkspaceTest do
  use Fahrgastrechte.DataCase, async: false

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures
  import Fahrgastrechte.DocumentsFixtures
  import Fahrgastrechte.RailFixtures

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.ClaimWorkspace
  alias Fahrgastrechte.Rail
  alias Fahrgastrechte.Tickets

  describe "load/2" do
    test "builds one checked snapshot for the scoped workspace" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, workspace} = ClaimWorkspace.load(scope, claim.id)

      assert workspace.claim.id == claim.id
      assert workspace.claim_changeset.data.id == claim.id
      assert workspace.documents_by_kind == %{}
      assert workspace.documents_by_id == %{}
      assert workspace.suggestions_by_id == %{}
      assert workspace.suggestion_groups == %{route: [], booking: [], other: []}
      assert workspace.planned_journey == nil
      assert workspace.actual_journey == nil
      assert workspace.status_history != []
      assert workspace.step_states.claim == :confirmed
      assert workspace.step_states.documents == :open
      refute workspace.review_complete?
      assert {:error, %{type: :incomplete}} = workspace.readiness
    end

    test "does not expose another user's workspace" do
      owner_scope = scope_fixture()
      foreign_scope = scope_fixture()
      claim = claim_fixture(owner_scope)

      assert {:error, :not_found} = ClaimWorkspace.load(foreign_scope, claim.id)
      assert {:error, :not_authenticated} = ClaimWorkspace.load(nil, claim.id)
    end
  end

  describe "accept_suggestions/3" do
    test "rolls back claim values when any suggestion is outside the checked set" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      origin = Enum.find(suggestions, &(&1.field == :origin))
      forged = %{origin | id: Ecto.UUID.generate()}

      assert {:error, :not_found} =
               ClaimWorkspace.accept_suggestions(scope, claim, [origin, forged])

      assert {:ok, unchanged} = Claims.get_claim(scope, claim.id)
      assert unchanged.origin == claim.origin
      assert unchanged.lock_version == claim.lock_version

      assert {:ok, current_suggestions} = Tickets.list_claim_suggestions(scope, claim.id)
      assert Enum.find(current_suggestions, &(&1.id == origin.id)).state == :proposed
    end

    test "updates the claim and suggestion together" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      origin = Enum.find(suggestions, &(&1.field == :origin))

      assert {:ok, %{claim: updated, suggestions: [accepted]}} =
               ClaimWorkspace.accept_suggestions(scope, claim, [origin])

      assert updated.origin == "Teststadt Hbf"
      assert accepted.id == origin.id
      assert accepted.state == :accepted
    end

    test "rejects mutating a sent claim, even for fields not mapped to claim attrs" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      order_number = Enum.find(suggestions, &(&1.field == :order_number))

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:error, :not_editable} =
               ClaimWorkspace.accept_suggestions(scope, sent, [order_number])
    end
  end

  describe "reject_suggestions/3" do
    test "rejects the checked suggestions on a draft claim" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      origin = Enum.find(suggestions, &(&1.field == :origin))

      assert {:ok, %{claim: unchanged, suggestions: [rejected]}} =
               ClaimWorkspace.reject_suggestions(scope, claim, [origin])

      assert unchanged.status == :draft
      assert rejected.id == origin.id
      assert rejected.state == :rejected
    end

    test "on a ready claim, invalidates the output atomically alongside the rejection" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      origin = Enum.find(suggestions, &(&1.field == :origin))
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:ok, %{claim: reopened, suggestions: [rejected]}} =
               ClaimWorkspace.reject_suggestions(scope, ready, [origin])

      assert reopened.status == :draft
      assert reopened.generated_at == nil
      assert rejected.state == :rejected
    end

    test "rejects mutating a sent claim" do
      scope = scope_fixture()
      initial_claim = claim_fixture(scope)
      {document, claim} = document_fixture(scope, initial_claim)

      assert {:ok, %{suggestions: suggestions}} =
               Tickets.analyze_document(scope, claim.id, document.id, claim.lock_version)

      origin = Enum.find(suggestions, &(&1.field == :origin))

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:error, :not_editable} =
               ClaimWorkspace.reject_suggestions(scope, sent, [origin])
    end
  end

  describe "confirm_actual_journey/4 — missed_connection" do
    defp missed_connection_params do
      %{
        "origin_name" => "Berlin Hbf",
        "destination_name" => "Hannover Hbf",
        "train_category" => "ICE",
        "train_number" => "100",
        "scheduled_departure" => "15.07.2026, 08:00",
        "scheduled_arrival" => "15.07.2026, 09:00",
        "actual_departure" => "15.07.2026, 08:10",
        "actual_arrival" => "15.07.2026, 09:20",
        "missed_connection_category" => "IC",
        "missed_connection_number" => "200",
        "missed_connection_departure" => "15.07.2026, 10:00",
        "missed_connection_arrival" => "15.07.2026, 11:00"
      }
    end

    test "persists a feeder and an onward segment with a connection gap" do
      scope = scope_fixture()
      claim = claim_fixture(scope, %{"disruption_cause" => "missed_connection"})

      assert {:ok, %{claim: planned_claim, journey: planned_journey}} =
               Rail.confirm_journey(
                 scope,
                 claim.id,
                 :planned,
                 [segment_attributes()],
                 claim.lock_version
               )

      assert {:ok, %{journey: actual_journey}} =
               ClaimWorkspace.confirm_actual_journey(
                 scope,
                 planned_claim,
                 planned_journey,
                 missed_connection_params()
               )

      assert [feeder, onward] = actual_journey.segments
      assert feeder.train_number == "100"
      assert feeder.destination_name == "Hannover Hbf"
      assert onward.train_number == "200"
      assert onward.origin_name == "Hannover Hbf"
      assert onward.destination_name == "Hamburg Hbf"
    end

    test "requires a planned journey first" do
      scope = scope_fixture()
      claim = claim_fixture(scope, %{"disruption_cause" => "missed_connection"})

      assert {:error, :missing_planned} =
               ClaimWorkspace.confirm_actual_journey(
                 scope,
                 claim,
                 nil,
                 missed_connection_params()
               )
    end

    test "rejects an onward arrival before its departure" do
      scope = scope_fixture()
      claim = claim_fixture(scope, %{"disruption_cause" => "missed_connection"})

      assert {:ok, %{claim: planned_claim, journey: planned_journey}} =
               Rail.confirm_journey(
                 scope,
                 claim.id,
                 :planned,
                 [segment_attributes()],
                 claim.lock_version
               )

      invalid_params =
        missed_connection_params()
        |> Map.put("missed_connection_departure", "15.07.2026, 11:00")
        |> Map.put("missed_connection_arrival", "15.07.2026, 10:00")

      assert {:error, :invalid_time_order} =
               ClaimWorkspace.confirm_actual_journey(
                 scope,
                 planned_claim,
                 planned_journey,
                 invalid_params
               )
    end

    test "reload reconstructs the form with both legs" do
      scope = scope_fixture()
      claim = claim_fixture(scope, %{"disruption_cause" => "missed_connection"})

      assert {:ok, %{claim: planned_claim, journey: planned_journey}} =
               Rail.confirm_journey(
                 scope,
                 claim.id,
                 :planned,
                 [segment_attributes()],
                 claim.lock_version
               )

      assert {:ok, %{claim: updated_claim}} =
               ClaimWorkspace.confirm_actual_journey(
                 scope,
                 planned_claim,
                 planned_journey,
                 missed_connection_params()
               )

      assert {:ok, workspace} = ClaimWorkspace.load(scope, updated_claim.id)
      data = workspace.actual_form_data

      assert data["origin_name"] == "Berlin Hbf"
      assert data["destination_name"] == "Hannover Hbf"
      assert data["actual_departure"] == "2026-07-15T08:10"
      assert data["actual_arrival"] == "2026-07-15T09:20"
      assert data["missed_connection_category"] == "IC"
      assert data["missed_connection_number"] == "200"
      assert data["missed_connection_departure"] == "2026-07-15T10:00"
      assert data["missed_connection_arrival"] == "2026-07-15T11:00"
    end
  end

  describe "search_connections/3" do
    setup do
      previous_rail_config = Application.fetch_env!(:fahrgastrechte, Fahrgastrechte.Rail)

      Application.put_env(
        :fahrgastrechte,
        Fahrgastrechte.Rail,
        Keyword.put(previous_rail_config, :provider, Fahrgastrechte.TestRailProvider)
      )

      on_exit(fn ->
        Application.put_env(:fahrgastrechte, Fahrgastrechte.Rail, previous_rail_config)
      end)

      :ok
    end

    test "reuses a resolved station id without re-searching when the text is unchanged" do
      scope = scope_fixture()

      claim =
        claim_fixture(scope, %{
          "origin" => "Hannover Hbf",
          "origin_station_id" => %{
            "provider" => "Fahrgastrechte.TestRailProvider",
            "value" => "8000152"
          },
          "destination" => "Frankfurt(M) Flughafen Fernbf",
          "destination_station_id" => %{
            "provider" => "Fahrgastrechte.TestRailProvider",
            "value" => "8070004"
          }
        })

      params = %{
        "origin" => claim.origin,
        "destination" => claim.destination,
        "departure_at" => "2026-08-02T08:00"
      }

      assert {:ok, _candidates} = ClaimWorkspace.search_connections(scope, claim, params)

      refute_received {:test_rail_provider_search_stations, _query}
      assert_received {:test_rail_provider_search_connections, query}
      assert query.origin == %{provider: Fahrgastrechte.TestRailProvider, value: "8000152"}

      assert query.destination == %{
               provider: Fahrgastrechte.TestRailProvider,
               value: "8070004"
             }
    end

    test "falls back to a fresh station search when the text was edited" do
      scope = scope_fixture()

      claim =
        claim_fixture(scope, %{
          "origin" => "Hannover Hbf",
          "origin_station_id" => %{
            "provider" => "Fahrgastrechte.TestRailProvider",
            "value" => "8000152"
          }
        })

      params = %{
        "origin" => "Hannover+City",
        "destination" => claim.destination,
        "departure_at" => "2026-08-02T08:00"
      }

      assert {:ok, _candidates} = ClaimWorkspace.search_connections(scope, claim, params)

      assert_received {:test_rail_provider_search_stations, "Hannover+City"}
      assert_received {:test_rail_provider_search_connections, query}
      assert query.origin == %{provider: Fahrgastrechte.TestRailProvider, value: "9999999"}
    end
  end
end
