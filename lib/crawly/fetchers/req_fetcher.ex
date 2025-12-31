defmodule Crawly.Fetchers.ReqFetcher do
  @moduledoc """
  Fetcher implementation using Req HTTP client.

  Req provides better connection pooling via Finch and modern features
  like automatic retries, compression, and easy proxy support.

  ## Proxy Configuration

  Pass proxy options via client_options:

      {Crawly.Fetchers.ReqFetcher, [
        connect_options: [proxy: {:http, "proxy.example.com", 8080, []}]
      ]}

  ## Example Spider Configuration

      @impl Crawly.Spider
      def override_settings do
        [
          fetcher: {Crawly.Fetchers.ReqFetcher, []}
        ]
      end
  """

  @behaviour Crawly.Fetchers.Fetcher

  require Logger

  @impl true
  def fetch(request, client_options) do
    options =
      client_options
      |> Keyword.merge(headers: request.headers)
      |> Keyword.merge(request.options)

    case Req.get(request.url, options) do
      {:ok, %Req.Response{status: status, headers: headers, body: body}} ->
        # Return HTTPoison.Response for compatibility with Crawly.Worker
        # which pattern matches on %HTTPoison.Response{}
        response = %HTTPoison.Response{
          status_code: status,
          headers: Map.to_list(headers),
          body: body,
          request: %HTTPoison.Request{
            url: request.url,
            headers: request.headers
          },
          request_url: request.url
        }

        {:ok, response}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.debug(
          "ReqFetcher transport error for #{request.url}: #{inspect(reason)}"
        )

        {:error, reason}

      {:error, reason} ->
        Logger.debug("ReqFetcher error for #{request.url}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
