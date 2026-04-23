defmodule PhoenixReplay.SessionTest do
  use ExUnit.Case, async: false

  alias PhoenixReplay.Session
  alias PhoenixReplay.Storage.TestAdapter

  @identity %{kind: :anonymous, id: nil, attrs: %{}}

  setup do
    start_supervised!(TestAdapter)

    prior_storage = Application.get_env(:phoenix_replay, :storage)
    Application.put_env(:phoenix_replay, :storage, {TestAdapter, []})

    on_exit(fn ->
      stop_all_sessions()
      restore(:storage, prior_storage)
    end)

    %{topic_prefix: PhoenixReplay.Config.pubsub_topic_prefix()}
  end

  describe "append_events/3" do
    test "persists batch, broadcasts :event_batch, bumps watermark", ctx do
      session_id = unique_id()
      Phoenix.PubSub.subscribe(PhoenixReplay.PubSub, topic(ctx, session_id))
      {:ok, _pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

      events = [%{"type" => 0, "data" => %{}}]
      assert :ok = Session.append_events(session_id, 1, events)

      assert_receive {:event_batch, ^session_id, ^events, 1}
      assert {:ok, 1} = Session.seq_watermark(session_id)
      assert [{^session_id, 1, ^events}] = TestAdapter.appends()
    end

    test "dedups repeated seq silently — no second persist, no second broadcast", ctx do
      session_id = unique_id()
      Phoenix.PubSub.subscribe(PhoenixReplay.PubSub, topic(ctx, session_id))
      {:ok, _pid} = Session.start_session(session_id, @identity, seq_watermark: 0)

      events = [%{"e" => 1}]
      assert :ok = Session.append_events(session_id, 7, events)
      assert_receive {:event_batch, ^session_id, _, 7}

      assert :ok = Session.append_events(session_id, 7, events)
      refute_receive {:event_batch, ^session_id, _, 7}, 50

      assert length(TestAdapter.appends()) == 1
    end

    test "returns :no_session when no process is registered" do
      assert {:error, :no_session} =
               Session.append_events(unique_id(), 1, [%{"e" => 1}])
    end
  end

  describe "close/2" do
    test "broadcasts :session_closed and stops the process", ctx do
      session_id = unique_id()
      Phoenix.PubSub.subscribe(PhoenixReplay.PubSub, topic(ctx, session_id))
      {:ok, pid} = Session.start_session(session_id, @identity, seq_watermark: 0)
      ref = Process.monitor(pid)

      assert :ok = Session.close(session_id, :submitted)

      assert_receive {:session_closed, ^session_id, :submitted}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end

    test "returns :no_session when nothing is running" do
      assert {:error, :no_session} = Session.close(unique_id())
    end
  end

  describe "idle timeout" do
    test "fires :session_abandoned and stops the process after idle window", ctx do
      session_id = unique_id()
      Phoenix.PubSub.subscribe(PhoenixReplay.PubSub, topic(ctx, session_id))

      {:ok, pid} =
        Session.start_session(session_id, @identity, seq_watermark: 0, idle_timeout_ms: 30)

      ref = Process.monitor(pid)

      assert_receive {:session_abandoned, ^session_id, _last_event_at}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 200
    end

    test "append resets the idle timer", ctx do
      session_id = unique_id()
      Phoenix.PubSub.subscribe(PhoenixReplay.PubSub, topic(ctx, session_id))

      {:ok, pid} =
        Session.start_session(session_id, @identity, seq_watermark: 0, idle_timeout_ms: 80)

      Process.sleep(40)
      assert :ok = Session.append_events(session_id, 1, [%{"e" => 1}])
      Process.sleep(40)
      assert Process.alive?(pid)

      ref = Process.monitor(pid)
      assert_receive {:session_abandoned, ^session_id, _}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 200
    end
  end

  describe "lookup_or_start/2" do
    test "starts a fresh process when none is registered" do
      session_id = unique_id()
      assert {:error, :no_session} = Session.seq_watermark(session_id)

      assert {:ok, pid} = Session.lookup_or_start(session_id, @identity)
      assert Process.alive?(pid)
      assert {:ok, 0} = Session.seq_watermark(session_id)
    end

    test "seeds watermark from storage when adapter has prior events" do
      session_id = unique_id()
      TestAdapter.stub_resume(session_id, {:ok, session_id, 42})

      assert {:ok, _pid} = Session.lookup_or_start(session_id, @identity)
      assert {:ok, 42} = Session.seq_watermark(session_id)
    end

    test "returns the existing pid when one is already registered" do
      session_id = unique_id()
      {:ok, first} = Session.start_session(session_id, @identity, seq_watermark: 0)
      assert {:ok, ^first} = Session.lookup_or_start(session_id, @identity)
    end
  end

  # Helpers

  defp unique_id, do: "session-#{System.unique_integer([:positive])}"

  defp topic(%{topic_prefix: prefix}, session_id),
    do: "#{prefix}:session:#{session_id}"

  defp restore(key, nil), do: Application.delete_env(:phoenix_replay, key)
  defp restore(key, value), do: Application.put_env(:phoenix_replay, key, value)

  defp stop_all_sessions do
    PhoenixReplay.SessionRegistry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {_id, pid} ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 100)
    end)
  end
end
