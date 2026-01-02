defmodule Crawly.Middlewares.DomainFilter do
  @moduledoc """
  Filters out requests which are going outside of the crawled domain.

  The domain is obtained from:
  1. `base_url` setting passed at spider start (preferred)
  2. Spider's `c:Crawly.Spider.base_url` callback (fallback)

  ### Example Declaration
  ```
  middlewares: [
    Crawly.Middlewares.DomainFilter
  ]
  ```

  ### Dynamic base_url
  ```
  Crawly.Engine.start_spider(MySpider, base_url: "https://example.com")
  ```
  """

  @behaviour Crawly.Pipeline
  require Logger

  def run(request, state, _opts \\ []) do
    base_url =
      Crawly.Utils.get_settings(
        :base_url,
        state.spider_name,
        state.spider_name.base_url()
      )

    parsed_url = URI.parse(request.url)
    host = parsed_url.host

    case host != nil and String.contains?(base_url, host) do
      false ->
        Logger.debug(
          "Dropping request: #{inspect(request.url)} (domain filter)"
        )

        {false, state}

      true ->
        {request, state}
    end
  end
end
