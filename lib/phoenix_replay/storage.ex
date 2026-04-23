defmodule PhoenixReplay.Storage do
  @moduledoc """
  Behaviour that storage adapters implement.

  The core ingests session events and feedback submissions through this
  behaviour — it never touches a DB directly. Two adapters ship with
  PhoenixReplay:

    * `PhoenixReplay.Storage.Ecto` — default, writes a parent `feedbacks`
      row plus append-only `events` child rows. Small-footprint.
    * `PhoenixReplay.Storage.S3` — collapses long sessions into a single
      S3 blob; the parent row carries the `events_s3_key`.

  Ash users install `ash_feedback` and configure it as the storage
  adapter; writes then route through the Ash code interface, so
  policies and paper-trail fire normally.

  ## Callbacks

    * `start_session/2` — called on `POST /session`. Returns the
      `session_id` that subsequent event appends will reference.
    * `append_events/3` — called on `POST /events`. MUST be idempotent
      on `{session_id, seq}` (safe to retry).
    * `submit/3` — called on `POST /submit`. Persists the feedback row.
    * `fetch_feedback/2` — admin detail.
    * `fetch_events/1` — admin replay.
    * `list/2` — admin list.

  ## Identity

  Every callback receives an `identity` map produced by the configured
  `identify` hook:

      %{kind: :user | :api_key | :anonymous,
        id: String.t() | nil,
        attrs: map()}

  Identity is opaque to the core; adapters may index on it for
  tenant-level scoping.
  """

  @type session_id :: String.t()
  @type identity :: %{
          required(:kind) => atom(),
          optional(:id) => String.t() | nil,
          optional(:attrs) => map()
        }
  @type event_batch :: list(map())

  @callback start_session(identity(), now :: DateTime.t()) ::
              {:ok, session_id()} | {:error, term()}

  @doc """
  Resume check for a prior session. Called from `POST /session` when
  the client sends its `sessionStorage`-cached token. Identity is
  already verified upstream by `PhoenixReplay.SessionToken`'s
  signature (the token binds `session_id` to an `identity_hash`), so
  this callback only has to answer "is there still event data for
  this session, and is it recent enough to keep appending?"

  Returns the current `seq_watermark` (max `seq` written so far) so
  the resumed client can keep numbering from there.

  - `{:ok, session_id, seq_watermark}` — resumable; client continues.
  - `{:error, :not_found}` — no events on record for this session.
  - `{:error, :stale}` — last event older than
    `Config.session_idle_timeout_ms/0`; caller mints a fresh session.

  Added in ADR-0003 Phase 1. Adapters predating ADR-0003 need to
  implement this callback.
  """
  @callback resume_session(session_id(), now :: DateTime.t()) ::
              {:ok, session_id(), seq_watermark :: non_neg_integer()}
              | {:error, :not_found | :stale | term()}

  @callback append_events(session_id(), seq :: non_neg_integer(), event_batch()) ::
              :ok | {:error, term()}

  @callback submit(session_id(), params :: map(), identity()) ::
              {:ok, feedback :: struct() | map()} | {:error, term()}

  @callback fetch_feedback(id :: String.t(), opts :: keyword()) ::
              {:ok, struct() | map()} | {:error, :not_found | term()}

  @callback fetch_events(session_id()) ::
              {:ok, [map()]} | {:error, term()}

  @callback list(filters :: map(), pagination :: keyword()) ::
              {:ok, %{results: [struct() | map()], count: non_neg_integer()}}
              | {:error, term()}
end
