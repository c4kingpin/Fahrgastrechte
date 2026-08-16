defmodule Fahrgastrechte.ClaimsTest do
  use Fahrgastrechte.DataCase, async: true

  alias Fahrgastrechte.Claims
  alias Fahrgastrechte.Claims.StatusHistory
  alias Fahrgastrechte.Repo

  import Fahrgastrechte.AccountsFixtures
  import Fahrgastrechte.ClaimsFixtures

  describe "claim creation and scoping" do
    test "creates an opaque UUID claim with a readable number and initial history" do
      scope = scope_fixture()

      assert {:ok, claim} = Claims.create_claim(scope, valid_claim_attributes())
      assert {:ok, _uuid} = Ecto.UUID.cast(claim.id)
      assert claim.claim_number =~ ~r/^FR-\d{4}-[A-Z2-7]{8}$/
      assert claim.user_id == scope.user.id
      assert claim.status == :draft
      assert claim.compensation_method == :bank_transfer
      assert claim.lock_version == 1

      assert {:ok, [history]} = Claims.list_status_history(scope, claim.id)
      assert history.from_status == nil
      assert history.to_status == :draft
      assert history.reason == "created"
      assert history.actor_user_id == scope.user.id
    end

    test "never accepts ownership or lifecycle fields from input" do
      first_scope = scope_fixture()
      second_scope = scope_fixture()

      attrs =
        valid_claim_attributes(%{
          "user_id" => second_scope.user.id,
          "status" => "completed",
          "claim_number" => "FR-FORGED",
          "compensation_method" => "cash"
        })

      assert {:ok, claim} = Claims.create_claim(first_scope, attrs)
      assert claim.user_id == first_scope.user.id
      assert claim.status == :draft
      assert claim.compensation_method == :bank_transfer
      refute claim.claim_number == "FR-FORGED"
    end

    test "user A cannot read, list, update, delete or inspect user B's claim" do
      first_scope = scope_fixture()
      second_scope = scope_fixture()
      claim = claim_fixture(second_scope)

      assert {:error, :not_found} = Claims.get_claim(first_scope, claim.id)
      assert {:ok, []} = Claims.list_claims(first_scope)

      assert {:error, :not_found} =
               Claims.update_claim(first_scope, claim.id, %{"origin" => "Köln Hbf"}, 1)

      assert {:error, :not_found} = Claims.delete_claim(first_scope, claim.id, 1)
      assert {:error, :not_found} = Claims.list_status_history(first_scope, claim.id)
      assert {:error, :not_found} = Claims.export_readiness(first_scope, claim.id)
      assert {:ok, ^claim} = Claims.get_claim(second_scope, claim.id)
    end

    test "treats a malformed claim id as not found" do
      scope = scope_fixture()

      assert {:error, :not_found} = Claims.get_claim(scope, "not-a-uuid")
    end

    test "rejects missing scope instead of accepting a user or id" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:error, :not_authenticated} = Claims.create_claim(nil, %{})
      assert {:error, :not_authenticated} = Claims.get_claim(scope.user.id, claim.id)
      assert {:error, :not_authenticated} = Claims.list_claims(nil)

      assert {:error, :not_authenticated} =
               Claims.update_claim(nil, claim.id, %{"origin" => "Köln Hbf"}, 1)
    end
  end

  describe "updates and optimistic locking" do
    test "updates editable fields and rejects a stale autosave" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, updated} =
               Claims.update_claim(scope, claim.id, %{"origin" => "Köln Hbf"}, claim.lock_version)

      assert updated.origin == "Köln Hbf"
      assert updated.lock_version == claim.lock_version + 1

      assert {:error, :stale} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"destination" => "Bonn Hbf"},
                 claim.lock_version
               )

      assert {:ok, loaded} = Claims.get_claim(scope, claim.id)
      assert loaded.destination == "Hamburg Hbf"
    end

    test "clears a resolved station id when its text changes without a matching new id" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      station_id = %{
        "provider" => "Fahrgastrechte.Rail.Providers.Timetables",
        "value" => "8000152"
      }

      assert {:ok, resolved} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"origin" => "Hannover Hbf", "origin_station_id" => station_id},
                 claim.lock_version
               )

      assert resolved.origin == "Hannover Hbf"
      assert resolved.origin_station_id == station_id

      assert {:ok, edited} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"origin" => "Hannover+City"},
                 resolved.lock_version
               )

      assert edited.origin == "Hannover+City"
      assert edited.origin_station_id == nil
    end

    test "dependent draft changes advance the lock and reject a stale mutation" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, invalidated} =
               Claims.invalidate_output(scope, claim.id, claim.lock_version)

      assert invalidated.status == :draft
      assert invalidated.lock_version == claim.lock_version + 1

      assert {:error, :stale} =
               Claims.invalidate_output(scope, claim.id, claim.lock_version)
    end

    test "changing a ready claim atomically invalidates its output" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      assert {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      assert ready.generated_at

      assert {:ok, draft} =
               Claims.update_claim(
                 scope,
                 ready.id,
                 %{"destination" => "Bremen Hbf"},
                 ready.lock_version
               )

      assert draft.status == :draft
      assert draft.generated_at == nil
      assert draft.destination == "Bremen Hbf"

      assert {:ok, history} = Claims.list_status_history(scope, claim.id)

      assert Enum.map(history, &{&1.from_status, &1.to_status, &1.reason}) == [
               {nil, :draft, "created"},
               {:draft, :ready, "output_generated"},
               {:ready, :draft, "claim_updated"}
             ]
    end

    test "sent and completed claims require lifecycle actions before editing" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:error, :not_editable} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"origin" => "München Hbf"},
                 sent.lock_version
               )

      {:ok, completed} =
        Claims.transition_claim(scope, claim.id, :completed, sent.lock_version)

      assert {:error, :not_editable} =
               Claims.update_claim(
                 scope,
                 claim.id,
                 %{"origin" => "München Hbf"},
                 completed.lock_version
               )
    end

    test "ensure_editable/3 shares the editability guard with update_claim/4" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, ^claim} = Claims.ensure_editable(scope, claim.id, claim.lock_version)
      assert {:error, :stale} = Claims.ensure_editable(scope, claim.id, claim.lock_version + 1)

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      assert {:ok, ^ready} = Claims.ensure_editable(scope, claim.id, ready.lock_version)

      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)
      assert {:error, :not_editable} = Claims.ensure_editable(scope, claim.id, sent.lock_version)

      {:ok, completed} = Claims.transition_claim(scope, claim.id, :completed, sent.lock_version)

      assert {:error, :not_editable} =
               Claims.ensure_editable(scope, claim.id, completed.lock_version)

      assert {:error, :not_authenticated} = Claims.ensure_editable(nil, claim.id, 1)
    end
  end

  describe "status lifecycle" do
    test "returns structured completeness errors before ready" do
      scope = scope_fixture()
      assert {:ok, claim} = Claims.create_claim(scope)

      assert {:error, %{type: :incomplete, errors: errors}} =
               Claims.export_readiness(scope, claim.id)

      assert errors == [
               %{source: :claim, field: :travel_date, code: :required},
               %{source: :claim, field: :origin, code: :required},
               %{source: :claim, field: :destination, code: :required},
               %{source: :claim, field: :journey_outcome, code: :required},
               %{source: :claim, field: :disruption_cause, code: :required}
             ]

      assert {:error, %{type: :incomplete, errors: ^errors}} =
               Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
    end

    test "supports the complete forward lifecycle and timestamps every state" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      assert ready.status == :ready
      assert ready.generated_at

      assert {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)
      assert sent.status == :sent
      assert sent.generated_at
      assert sent.sent_at

      assert {:ok, completed} =
               Claims.transition_claim(scope, claim.id, :completed, sent.lock_version)

      assert completed.status == :completed
      assert completed.generated_at
      assert completed.sent_at
      assert completed.completed_at

      assert {:ok, history} = Claims.list_status_history(scope, claim.id)

      assert Enum.map(history, &{&1.from_status, &1.to_status}) == [
               {nil, :draft},
               {:draft, :ready},
               {:ready, :sent},
               {:sent, :completed}
             ]
    end

    test "allows deliberate ready and sent corrections back to draft" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:ok, first_draft} =
               Claims.transition_claim(scope, claim.id, :draft, ready.lock_version)

      assert first_draft.status == :draft
      assert first_draft.generated_at == nil

      {:ok, ready_again} =
        Claims.transition_claim(scope, claim.id, :ready, first_draft.lock_version)

      {:ok, sent} =
        Claims.transition_claim(scope, claim.id, :sent, ready_again.lock_version)

      assert {:ok, second_draft} =
               Claims.transition_claim(scope, claim.id, :draft, sent.lock_version)

      assert second_draft.status == :draft
      assert second_draft.generated_at == nil
      assert second_draft.sent_at == nil
    end

    test "enforces the complete status transition matrix" do
      scope = scope_fixture()
      statuses = [:draft, :ready, :sent, :completed]

      allowed = %{
        draft: [:ready],
        ready: [:draft, :sent],
        sent: [:draft, :completed],
        completed: []
      }

      for from_status <- statuses, to_status <- statuses do
        claim = claim_in_status(scope, from_status)

        result =
          Claims.transition_claim(scope, claim.id, to_status, claim.lock_version)

        if to_status in Map.fetch!(allowed, from_status) do
          assert {:ok, transitioned} = result
          assert transitioned.status == to_status
        else
          assert {:error, {:invalid_transition, ^from_status, ^to_status}} = result
        end
      end
    end

    test "rejects all shortcuts and transitions out of completed" do
      scope = scope_fixture()
      claim = claim_fixture(scope)

      assert {:error, {:invalid_transition, :draft, :sent}} =
               Claims.transition_claim(scope, claim.id, :sent, claim.lock_version)

      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)

      assert {:error, {:invalid_transition, :ready, :completed}} =
               Claims.transition_claim(scope, claim.id, :completed, ready.lock_version)

      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)
      {:ok, completed} = Claims.transition_claim(scope, claim.id, :completed, sent.lock_version)

      assert {:error, {:invalid_transition, :completed, :draft}} =
               Claims.transition_claim(scope, claim.id, :draft, completed.lock_version)

      assert {:error, {:invalid_transition, :completed, :unknown}} =
               Claims.transition_claim(scope, claim.id, :unknown, completed.lock_version)
    end

    test "dependent changes invalidate a sent output with a dedicated reason" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
      {:ok, sent} = Claims.transition_claim(scope, claim.id, :sent, ready.lock_version)

      assert {:ok, draft} = Claims.invalidate_output(scope, claim.id, sent.lock_version)
      assert draft.status == :draft
      assert draft.generated_at == nil
      assert draft.sent_at == nil

      assert {:ok, history} = Claims.list_status_history(scope, claim.id)
      assert List.last(history).reason == "dependent_data_changed"
    end
  end

  describe "wave one export fields" do
    test "stores journey outcome, disruption cause and return direction independently" do
      scope = scope_fixture()

      claim =
        claim_fixture(scope, %{
          "journey_outcome" => "aborted",
          "disruption_cause" => "cancellation",
          "journey_direction" => "return"
        })

      assert claim.journey_outcome == :aborted
      assert claim.disruption_cause == :cancellation
      assert claim.journey_direction == :return
      assert {:ok, ^claim} = Claims.export_readiness(scope, claim.id)
    end

    test "reports an incompatible missed connection before a journey was started" do
      scope = scope_fixture()

      claim =
        claim_fixture(scope, %{
          "journey_outcome" => "not_started",
          "disruption_cause" => "missed_connection"
        })

      assert {:error, %{type: :incomplete, errors: errors}} =
               Claims.export_readiness(scope, claim.id)

      assert errors == [
               %{source: :claim, field: :disruption_cause, code: :invalid_for_outcome}
             ]
    end
  end

  describe "filters and deletion" do
    test "aggregates scoped dashboard counts by lifecycle status" do
      scope = scope_fixture()
      other_scope = scope_fixture()

      _draft = claim_in_status(scope, :draft)
      _ready = claim_in_status(scope, :ready)
      _sent = claim_in_status(scope, :sent)
      _completed = claim_in_status(scope, :completed)
      _foreign_completed = claim_in_status(other_scope, :completed)

      assert {:ok, %{total: 4, open: 3, completed: 1}} = Claims.dashboard_counts(scope)

      assert {:ok, %{total: 1, open: 0, completed: 1}} =
               Claims.dashboard_counts(other_scope)

      assert {:error, :not_authenticated} = Claims.dashboard_counts(nil)
    end

    test "filters only scoped claims by status, date, route and claim number" do
      scope = scope_fixture()
      other_scope = scope_fixture()

      berlin = claim_fixture(scope, %{"travel_date" => ~D[2026-07-10]})

      munich =
        claim_fixture(scope, %{
          "travel_date" => ~D[2026-08-20],
          "origin" => "München Hbf",
          "destination" => "Nürnberg Hbf",
          "disruption_cause" => "cancellation"
        })

      _foreign = claim_fixture(other_scope, %{"origin" => "München Hbf"})
      {:ok, ready_munich} = Claims.transition_claim(scope, munich.id, :ready, munich.lock_version)

      assert {:ok, [^ready_munich]} = Claims.list_claims(scope, status: :ready)
      assert {:ok, [^berlin]} = Claims.list_claims(scope, travel_date: "2026-07-10")
      assert {:ok, [^ready_munich]} = Claims.list_claims(scope, route: "nürnberg")
      assert {:ok, [^ready_munich]} = Claims.list_claims(scope, date_from: ~D[2026-08-01])
      assert {:ok, [^berlin]} = Claims.list_claims(scope, date_to: ~D[2026-07-31])

      number_fragment = String.slice(berlin.claim_number, -4, 4)
      assert {:ok, [^berlin]} = Claims.list_claims(scope, claim_number: number_fragment)
      assert {:ok, unfiltered} = Claims.list_claims(scope, route: "   ")
      assert Enum.sort(Enum.map(unfiltered, & &1.id)) == Enum.sort([berlin.id, ready_munich.id])
      assert {:error, {:invalid_filter, :status}} = Claims.list_claims(scope, status: :unknown)

      assert {:error, {:invalid_filter, :date_from}} =
               Claims.list_claims(scope, date_from: "not-a-date")
    end

    test "deletes a scoped claim and its status history with optimistic locking" do
      scope = scope_fixture()
      claim = claim_fixture(scope)
      assert Repo.aggregate(StatusHistory, :count) == 1

      assert {:error, :stale} = Claims.delete_claim(scope, claim.id, claim.lock_version + 1)
      assert {:ok, deleted} = Claims.delete_claim(scope, claim.id, claim.lock_version)
      assert deleted.id == claim.id
      assert {:error, :not_found} = Claims.get_claim(scope, claim.id)
      assert Repo.aggregate(StatusHistory, :count) == 0
    end
  end

  defp claim_in_status(scope, :draft), do: claim_fixture(scope)

  defp claim_in_status(scope, :ready) do
    claim = claim_fixture(scope)
    {:ok, ready} = Claims.transition_claim(scope, claim.id, :ready, claim.lock_version)
    ready
  end

  defp claim_in_status(scope, :sent) do
    ready = claim_in_status(scope, :ready)
    {:ok, sent} = Claims.transition_claim(scope, ready.id, :sent, ready.lock_version)
    sent
  end

  defp claim_in_status(scope, :completed) do
    sent = claim_in_status(scope, :sent)
    {:ok, completed} = Claims.transition_claim(scope, sent.id, :completed, sent.lock_version)
    completed
  end
end
