defmodule Fahrgastrechte.Accounts.Scope do
  @moduledoc """
  Carries the authenticated user through web and context boundaries.

  User-owned data must be queried with this scope. A bare resource ID is never
  sufficient authorization.
  """

  alias Fahrgastrechte.Accounts.User

  defstruct user: nil

  @type t :: %__MODULE__{user: User.t()}

  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
