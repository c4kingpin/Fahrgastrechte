defmodule Fahrgastrechte.Rail.Candidate do
  @moduledoc """
  Provider-neutral, unconfirmed connection candidate.

  Candidates are deliberately transient. Only a user-confirmed selection is
  persisted as a journey and ordered segments.
  """

  @enforce_keys [:id, :segments, :source, :fetched_at]
  defstruct [:id, :segments, :source, :fetched_at]

  @type t :: %__MODULE__{
          id: map(),
          segments: [map()],
          source: String.t(),
          fetched_at: DateTime.t()
        }
end
