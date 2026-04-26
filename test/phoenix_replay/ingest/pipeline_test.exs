defmodule PhoenixReplay.Ingest.PipelineTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [put_req_header: 3]
  import Phoenix.ConnTest, only: [build_conn: 0]

  alias PhoenixReplay.Ingest.{Error, Pipeline}

  describe "check_body_size/2 — strict content-length parsing" do
    @opts [limit_key: :max_batch_bytes, default: 1_000]

    test "ok when header is absent" do
      assert {:ok, _ctx} = Pipeline.check_body_size(ctx(build_conn()), @opts)
    end

    test "ok when content-length is under the cap" do
      conn = build_conn() |> put_req_header("content-length", "500")
      assert {:ok, _ctx} = Pipeline.check_body_size(ctx(conn), @opts)
    end

    test "ok at the boundary (n == max)" do
      conn = build_conn() |> put_req_header("content-length", "1000")
      assert {:ok, _ctx} = Pipeline.check_body_size(ctx(conn), @opts)
    end

    test "413 when content-length exceeds the cap" do
      conn = build_conn() |> put_req_header("content-length", "1001")
      assert {:error, %Error{status: 413, code: "body_too_large"}} =
               Pipeline.check_body_size(ctx(conn), @opts)
    end

    test "400 when content-length is negative" do
      conn = build_conn() |> put_req_header("content-length", "-1000")
      assert {:error, %Error{status: 400, code: "invalid_content_length"}} =
               Pipeline.check_body_size(ctx(conn), @opts)
    end

    test "400 when content-length has trailing garbage" do
      conn = build_conn() |> put_req_header("content-length", "100abc")
      assert {:error, %Error{status: 400, code: "invalid_content_length"}} =
               Pipeline.check_body_size(ctx(conn), @opts)
    end

    test "400 when content-length is non-numeric" do
      conn = build_conn() |> put_req_header("content-length", "abc")
      assert {:error, %Error{status: 400, code: "invalid_content_length"}} =
               Pipeline.check_body_size(ctx(conn), @opts)
    end

    test "400 when there are conflicting content-length headers" do
      # Plug.Conn.put_req_header overwrites; use the underlying req_headers
      # list to simulate request-smuggling — two header values for the
      # same name.
      conn = %{
        build_conn()
        | req_headers: [{"content-length", "100"}, {"content-length", "200"}]
      }

      assert {:error, %Error{status: 400, code: "invalid_content_length"}} =
               Pipeline.check_body_size(ctx(conn), @opts)
    end
  end

  defp ctx(conn), do: %{conn: conn, limits: []}
end
