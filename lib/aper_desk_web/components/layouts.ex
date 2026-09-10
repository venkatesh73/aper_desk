defmodule AperDeskWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AperDeskWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  The outer wrapper every page renders inside.

  Deliberately thin: it carries the flash group and nothing else. Chrome is the
  page's own business — the marketing site has an editorial nav, the signed-in
  app has a sidebar, and a client gallery has neither. A layout that imposed one
  of those on all three would be fought by two of them.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    {render_slot(@inner_block)}
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Flash messages, styled with the design tokens.

  Replaces the generated version, which emitted daisyUI classes this
  application does not load — so a flash rendered as unstyled text at the foot
  of the page instead of as a notice.

  The two connection banners are LiveView's own: they are hidden until the
  socket reports itself disconnected, so a dropped connection says so rather
  than leaving a page that has quietly stopped responding.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="flash-group" aria-live="polite">
      <.notice kind={:info} flash={@flash} />
      <.notice kind={:error} flash={@flash} />

      <div
        id="client-error"
        class="flash error"
        hidden
        phx-disconnected={JS.remove_attribute("hidden", to: "#client-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#client-error")}
      >
        <span><b>We can't reach the server</b>Trying to reconnect…</span>
      </div>

      <div
        id="server-error"
        class="flash error"
        hidden
        phx-disconnected={JS.remove_attribute("hidden", to: "#server-error")}
        phx-connected={JS.set_attribute({"hidden", ""}, to: "#server-error")}
      >
        <span><b>Something went wrong</b>Trying to reconnect…</span>
      </div>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :flash, :map, required: true

  defp notice(assigns) do
    assigns = assign(assigns, :message, Phoenix.Flash.get(assigns.flash, assigns.kind))

    ~H"""
    <div
      :if={@message}
      id={"flash-#{@kind}"}
      class={["flash", to_string(@kind)]}
      role={if @kind == :error, do: "alert", else: "status"}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> JS.hide(to: "#flash-#{@kind}")}
    >
      <span>
        <b>{if @kind == :error, do: "Something went wrong", else: "Done"}</b>{@message}
      </span>
      <button type="button" aria-label="Dismiss">&times;</button>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
