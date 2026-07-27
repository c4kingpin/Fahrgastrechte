defmodule FahrgastrechteWeb.ProfileLive do
  use FahrgastrechteWeb, :live_view

  alias Fahrgastrechte.Accounts

  @impl true
  def mount(_params, _session, socket) do
    changeset = Accounts.change_profile(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, "Reisendenprofil")
     |> assign(:profile_complete?, Accounts.profile_complete?(socket.assigns.current_scope))
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("profile_validate", %{"profile" => profile_params}, socket) do
    changeset =
      socket.assigns.current_scope
      |> Accounts.change_profile(profile_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("profile_save", %{"profile" => profile_params}, socket) do
    case Accounts.update_profile(socket.assigns.current_scope, profile_params) do
      {:ok, _profile} ->
        changeset = Accounts.change_profile(socket.assigns.current_scope)

        {:noreply,
         socket
         |> put_flash(:info, "Dein Reisendenprofil wurde sicher gespeichert.")
         |> assign(:profile_complete?, Accounts.profile_complete?(socket.assigns.current_scope))
         |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Das Profil konnte nicht gespeichert werden.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="profile-page" class={["space-y-8"]}>
        <section class={[
          "overflow-hidden rounded-3xl bg-slate-950 px-6 py-8 text-white shadow-xl sm:px-10"
        ]}>
          <div class={["flex flex-col gap-6 sm:flex-row sm:items-end sm:justify-between"]}>
            <div class={["max-w-xl"]}>
              <p class={["text-xs font-semibold uppercase tracking-[0.24em] text-rose-300"]}>
                Stammdaten
              </p>
              <h1 class={["mt-3 text-3xl font-semibold tracking-tight sm:text-4xl"]}>
                Dein Reisendenprofil
              </h1>
              <p class={["mt-3 text-sm leading-6 text-slate-300"]}>
                Diese Angaben werden später in deine Fahrgastrechte-Anträge übernommen.
                Bankdaten liegen verschlüsselt in der Datenbank.
              </p>
            </div>
            <div
              id="profile-completeness"
              class={[
                "inline-flex w-fit items-center gap-2 rounded-full px-3 py-1.5 text-xs font-semibold",
                if(@profile_complete?,
                  do: "bg-emerald-400/15 text-emerald-200",
                  else: "bg-amber-400/15 text-amber-200"
                )
              ]}
            >
              <span class={["size-2 rounded-full bg-current"]}></span>
              {if(@profile_complete?, do: "Vollständig", else: "Noch unvollständig")}
            </div>
          </div>
        </section>

        <.form
          for={@form}
          id="profile-form"
          phx-change="profile_validate"
          phx-submit="profile_save"
          class={["space-y-8"]}
        >
          <section class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}>
            <div class={["mb-6"]}>
              <h2 class={["text-lg font-semibold text-slate-950"]}>Persönliche Angaben</h2>
              <p class={["mt-1 text-sm text-slate-500"]}>
                Felder mit * werden für den Antrag benötigt.
              </p>
            </div>

            <div class={["grid gap-5 sm:grid-cols-2"]}>
              <.input
                field={@form[:salutation]}
                id="profile-salutation"
                type="select"
                label="Anrede *"
                prompt="Bitte auswählen"
                options={[{"Frau", "female"}, {"Herr", "male"}, {"Neutrale Anrede", "neutral"}]}
              />
              <.input
                field={@form[:title]}
                id="profile-title"
                label="Titel"
                autocomplete="honorific-prefix"
              />
              <.input
                field={@form[:first_name]}
                id="profile-first-name"
                label="Vorname *"
                autocomplete="given-name"
              />
              <.input
                field={@form[:last_name]}
                id="profile-last-name"
                label="Nachname *"
                autocomplete="family-name"
              />
              <.input
                field={@form[:street]}
                id="profile-street"
                label="Straße *"
                autocomplete="address-line1"
              />
              <.input
                field={@form[:house_number]}
                id="profile-house-number"
                label="Hausnummer *"
                autocomplete="address-line2"
              />
              <.input
                field={@form[:postal_code]}
                id="profile-postal-code"
                label="Postleitzahl *"
                autocomplete="postal-code"
              />
              <.input
                field={@form[:city]}
                id="profile-city"
                label="Ort *"
                autocomplete="address-level2"
              />
              <.input
                field={@form[:country]}
                id="profile-country"
                label="Staat *"
                autocomplete="country-name"
              />
              <.input
                field={@form[:phone_number]}
                id="profile-phone-number"
                type="tel"
                label="Telefonnummer"
                autocomplete="tel"
              />
            </div>
          </section>

          <section class={["rounded-3xl border border-slate-200 bg-white p-6 shadow-sm sm:p-8"]}>
            <div class={["mb-6 flex items-start gap-3"]}>
              <span class={["mt-0.5 rounded-xl bg-rose-50 p-2 text-rose-700"]}>
                <.icon name="hero-lock-closed" class="size-5" />
              </span>
              <div>
                <h2 class={["text-lg font-semibold text-slate-950"]}>Auszahlung</h2>
                <p class={["mt-1 text-sm leading-6 text-slate-500"]}>
                  IBAN und BIC werden authentifiziert verschlüsselt gespeichert und nicht protokolliert.
                </p>
              </div>
            </div>

            <div class={["grid gap-5"]}>
              <.input
                field={@form[:account_holder]}
                id="profile-account-holder"
                label="Kontoinhaber *"
                autocomplete="name"
              />
              <div class={["grid gap-5 sm:grid-cols-2"]}>
                <.input field={@form[:iban]} id="profile-iban" label="IBAN *" autocomplete="off" />
                <.input field={@form[:bic]} id="profile-bic" label="BIC *" autocomplete="off" />
              </div>
            </div>
          </section>

          <div class={["flex items-center justify-end"]}>
            <button
              id="profile-save"
              type="submit"
              phx-disable-with="Wird gespeichert …"
              class={[
                "inline-flex items-center gap-2 rounded-xl bg-rose-700 px-5 py-3 text-sm font-semibold text-white shadow-sm transition hover:-translate-y-0.5 hover:bg-rose-800 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-rose-700 disabled:cursor-wait disabled:opacity-70"
              ]}
            >
              <.icon name="hero-check" class="size-5" /> Profil speichern
            </button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp assign_form(socket, changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
