defmodule PhoenixReplay.ConnCase do
  @moduledoc false
  # Shared test setup for controller / LiveView tests. Configures a
  # `Plug.Conn` bound to `PhoenixReplay.TestEndpoint` so LV tests can
  # dispatch against real routes.

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint PhoenixReplay.TestEndpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
