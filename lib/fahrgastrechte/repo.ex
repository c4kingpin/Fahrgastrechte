defmodule Fahrgastrechte.Repo do
  use Ecto.Repo,
    otp_app: :fahrgastrechte,
    adapter: Ecto.Adapters.Postgres
end
