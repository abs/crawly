defmodule Crawly.Fetchers.ReqFetcherTest do
  use ExUnit.Case

  alias Crawly.Fetchers.ReqFetcher

  setup do
    on_exit(fn ->
      :meck.unload()
    end)

    :ok
  end

  describe "fetch/2" do
    test "returns HTTPoison.Response on successful fetch" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn url, _opts ->
        assert url == "https://example.com"

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{"content-type" => ["text/html"]},
           body: "<html>Hello</html>"
         }}
      end)

      request = %Crawly.Request{
        url: "https://example.com",
        headers: [{"user-agent", "TestBot"}],
        options: []
      }

      {:ok, response} = ReqFetcher.fetch(request, [])

      assert %HTTPoison.Response{} = response
      assert response.status_code == 200
      assert response.body == "<html>Hello</html>"
      assert response.request_url == "https://example.com"
      assert {"content-type", ["text/html"]} in response.headers
    end

    test "passes headers from request" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn _url, opts ->
        assert opts[:headers] == [
                 {"user-agent", "CustomBot"},
                 {"accept", "text/html"}
               ]

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{},
           body: ""
         }}
      end)

      request = %Crawly.Request{
        url: "https://example.com",
        headers: [{"user-agent", "CustomBot"}, {"accept", "text/html"}],
        options: []
      }

      {:ok, _response} = ReqFetcher.fetch(request, [])
    end

    test "merges client_options with request options" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn _url, opts ->
        assert opts[:receive_timeout] == 30_000
        assert opts[:retry] == false

        {:ok,
         %Req.Response{
           status: 200,
           headers: %{},
           body: ""
         }}
      end)

      request = %Crawly.Request{
        url: "https://example.com",
        headers: [],
        options: [retry: false]
      }

      client_options = [receive_timeout: 30_000]

      {:ok, _response} = ReqFetcher.fetch(request, client_options)
    end

    test "returns error on transport error" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      request = %Crawly.Request{
        url: "https://example.com",
        headers: [],
        options: []
      }

      assert {:error, :timeout} = ReqFetcher.fetch(request, [])
    end

    test "returns error on connection refused" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      request = %Crawly.Request{
        url: "https://example.com",
        headers: [],
        options: []
      }

      assert {:error, :econnrefused} = ReqFetcher.fetch(request, [])
    end

    test "returns error on generic error" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn _url, _opts ->
        {:error, %RuntimeError{message: "something went wrong"}}
      end)

      request = %Crawly.Request{
        url: "https://example.com",
        headers: [],
        options: []
      }

      assert {:error, %RuntimeError{}} = ReqFetcher.fetch(request, [])
    end

    test "handles various HTTP status codes" do
      :meck.new(Req, [:passthrough])

      for status <- [200, 301, 404, 500] do
        :meck.expect(Req, :get, fn _url, _opts ->
          {:ok,
           %Req.Response{
             status: status,
             headers: %{},
             body: ""
           }}
        end)

        request = %Crawly.Request{
          url: "https://example.com",
          headers: [],
          options: []
        }

        {:ok, response} = ReqFetcher.fetch(request, [])
        assert response.status_code == status
      end
    end

    test "preserves original request in response" do
      :meck.new(Req, [:passthrough])

      :meck.expect(Req, :get, fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           headers: %{},
           body: ""
         }}
      end)

      request = %Crawly.Request{
        url: "https://example.com/page",
        headers: [{"user-agent", "Bot"}],
        options: []
      }

      {:ok, response} = ReqFetcher.fetch(request, [])

      assert response.request.url == "https://example.com/page"
      assert response.request.headers == [{"user-agent", "Bot"}]
    end
  end
end
