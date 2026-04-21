defmodule PhoenixReplay.ScrubTest do
  use ExUnit.Case, async: true

  alias PhoenixReplay.Scrub

  test "redacts bearer tokens in string leaves" do
    event = %{
      "type" => "console",
      "data" => %{"payload" => ["Authorization: Bearer abc.def-GHI_123"]}
    }

    [scrubbed] = Scrub.scrub_batch([event])

    assert scrubbed["data"]["payload"] == ["Authorization: [REDACTED]"]
  end

  test "redacts api_key patterns case-insensitively" do
    event = %{"msg" => "set API-Key=SECRET_VALUE_42"}

    [scrubbed] = Scrub.scrub_batch([event])
    refute scrubbed["msg"] =~ "SECRET_VALUE_42"
    assert scrubbed["msg"] =~ "[REDACTED]"
  end

  test "scrubs deny-listed query params in URLs" do
    event = %{"url" => "https://api.example.com/x?token=xyz123&page=2"}

    [scrubbed] = Scrub.scrub_batch([event])
    refute scrubbed["url"] =~ "xyz123"
    assert scrubbed["url"] =~ "token=%5BREDACTED%5D"
    assert scrubbed["url"] =~ "page=2"
  end

  test "leaves URLs without query strings alone" do
    event = %{"url" => "https://example.com/x"}
    [scrubbed] = Scrub.scrub_batch([event])
    assert scrubbed["url"] == "https://example.com/x"
  end

  test "recurses into nested lists and maps" do
    event = %{
      "children" => [
        %{"text" => "Bearer token-here"},
        %{"nested" => %{"deep" => "Bearer other-token"}}
      ]
    }

    [scrubbed] = Scrub.scrub_batch([event])
    assert get_in(scrubbed, ["children", Access.at(0), "text"]) == "[REDACTED]"
    assert get_in(scrubbed, ["children", Access.at(1), "nested", "deep"]) == "[REDACTED]"
  end

  test "preserves non-string leaves" do
    event = %{"n" => 42, "flag" => true, "float" => 1.5}
    [scrubbed] = Scrub.scrub_batch([event])
    assert scrubbed == event
  end
end
