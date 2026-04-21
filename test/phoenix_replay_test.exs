defmodule PhoenixReplayTest do
  use ExUnit.Case

  doctest PhoenixReplay

  describe "public API surface" do
    test "compiles and exposes the three contract modules" do
      assert Code.ensure_loaded?(PhoenixReplay.Router)
      assert Code.ensure_loaded?(PhoenixReplay.Storage)
      assert Code.ensure_loaded?(PhoenixReplay.Config)
    end

    test "Storage behaviour declares the expected callbacks" do
      callbacks = PhoenixReplay.Storage.behaviour_info(:callbacks)

      expected = [
        {:start_session, 2},
        {:append_events, 3},
        {:submit, 3},
        {:fetch_feedback, 2},
        {:fetch_events, 1},
        {:list, 2}
      ]

      for expected <- expected do
        assert expected in callbacks,
               "missing callback #{inspect(expected)} in PhoenixReplay.Storage"
      end
    end
  end
end
