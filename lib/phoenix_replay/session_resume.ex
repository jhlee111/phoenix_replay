defmodule PhoenixReplay.SessionResume do
  @moduledoc false
  # Resume-or-fresh decision for `/session` token minting (ADR-0003 Phase 2).
  #
  # Tries, in order:
  #   1. Verify the carry-over token against the caller's identity.
  #   2. Registry lookup of `PhoenixReplay.Session` — alive process →
  #      ask it for `seq_watermark/1`, no DB hit.
  #   3. Storage `resume_session/2` — covers the crash-restart case
  #      (process died, events table still has rows). On success,
  #      spawn a fresh Session seeded with the persisted watermark.
  #
  # Any failure along the chain — missing token, bad token, stale
  # session, identity mismatch, storage miss — collapses to `:fresh`.
  # The caller routes `:fresh` through the standard mint path; real
  # storage failures during fresh-mint are surfaced separately so we
  # don't mask infrastructure problems.

  alias PhoenixReplay.{Session, SessionToken, Storage}

  @type result :: {:ok, session_id :: String.t(), seq_watermark :: non_neg_integer()} | :fresh

  @doc """
  Attempt to resume a session given a (possibly nil) carry-over token,
  the caller's identity, and a `now` `DateTime` for the storage adapter.
  """
  @spec run(String.t() | nil, map(), DateTime.t()) :: result()
  def run(nil, _identity, _now), do: :fresh

  def run(token, identity, now) when is_binary(token) do
    with {:ok, session_id} <- SessionToken.verify(token, identity),
         {:ok, ^session_id, watermark} <- resolve(session_id, identity, now) do
      {:ok, session_id, watermark}
    else
      _ -> :fresh
    end
  end

  # Registry-first, DB-fallback. The DB-fallback branch also spawns a
  # Session process so subsequent /events POSTs find it without another
  # lookup-or-start round-trip.
  defp resolve(session_id, identity, now) do
    case Session.seq_watermark(session_id) do
      {:ok, watermark} ->
        {:ok, session_id, watermark}

      {:error, :no_session} ->
        case Storage.Dispatch.resume_session(session_id, now) do
          {:ok, ^session_id, watermark} ->
            with {:ok, _pid} <-
                   Session.start_session(session_id, identity, seq_watermark: watermark) do
              {:ok, session_id, watermark}
            end

          {:error, _} = err ->
            err
        end
    end
  end
end
