defmodule Crawly.Worker do
  @moduledoc """
  A worker process responsible for the actual work (fetching requests,
  processing responses)
  """
  use GenServer

  require Logger

  # define the default worker fetch interval.
  @default_backoff 10_000
  @start_timeout 1000

  @type spider_key() :: {Crawly.spider(), crawl_id :: binary()}

  defstruct backoff: @default_backoff,
            spider_name: nil,
            crawl_id: nil,
            spider_key: nil

  def start_link(spider_name: spider_name, crawl_id: crawl_id) do
    GenServer.start_link(__MODULE__,
      spider_name: spider_name,
      crawl_id: crawl_id
    )
  end

  def init(spider_name: spider_name, crawl_id: crawl_id) do
    Logger.metadata(crawl_id: crawl_id, spider_name: spider_name)
    Crawly.Utils.send_after(self(), :work, @start_timeout)

    {:ok,
     %Crawly.Worker{
       crawl_id: crawl_id,
       spider_name: spider_name,
       spider_key: {spider_name, crawl_id},
       backoff: @default_backoff
     }}
  end

  def handle_info(:work, state) do
    %{spider_name: spider_name, spider_key: spider_key, backoff: backoff} =
      state

    # Get a request from requests storage.
    new_backoff =
      case Crawly.RequestsStorage.pop(spider_key) do
        nil ->
          # Slow down a bit when there are no new URLs
          backoff * 2

        request ->
          # Process the request

          with {:ok, response} <-
                 get_response({request, spider_name, spider_key}),
               {:ok, parsed_item} <- parse_item(response),
               {:ok, :done} <- process_parsed_item(parsed_item) do
            :ok
          else
            {:error, reason} ->
              Logger.warning(
                "Crawly worker could not process the request to #{inspect(request.url)} reason: #{inspect(reason)}"
              )
          end

          @default_backoff
      end

    Crawly.Utils.send_after(self(), :work, new_backoff)

    {:noreply, %{state | backoff: new_backoff}}
  end

  @doc false
  @spec get_response({request, spider_name, spider_key}) :: result
        when request: Crawly.Request.t(),
             spider_name: atom(),
             spider_key: spider_key(),
             response: HTTPoison.Response.t(),
             result:
               {:ok, {response, spider_name, spider_key}} | {:error, term()}
  def get_response({request, spider_name, spider_key}) do
    # check if spider-level fetcher is set. Overrides the globally configured fetcher.
    # if not set, log warning for explicit config preferred,
    # get the globally-configured fetcher. Defaults to HTTPoisonFetcher

    {fetcher, options} =
      Crawly.Utils.get_settings(
        :fetcher,
        spider_name,
        {Crawly.Fetchers.HTTPoisonFetcher, []}
      )
      |> Crawly.Utils.unwrap_module_and_options()

    retry_options = Crawly.Utils.get_settings(:retry, spider_name, [])
    retry_codes = Keyword.get(retry_options, :retry_codes, [])

    case fetcher.fetch(request, options) do
      {:error, _reason} = err ->
        :ok = maybe_retry_request(spider_key, request)
        err

      {:ok, %HTTPoison.Response{status_code: code} = response} ->
        # Send the request back to re-try in case if retry status code requires
        # it.
        case code in retry_codes do
          true ->
            :ok = maybe_retry_request(spider_key, request)
            {:error, :retry}

          false ->
            {:ok, {response, spider_name, spider_key}}
        end
    end
  end

  @doc false
  @spec parse_item({response, spider_name, spider_key}) :: result
        when response: HTTPoison.Response.t(),
             spider_name: atom(),
             spider_key: spider_key(),
             parsed_item: Crawly.ParsedItem.t(),
             next: {parsed_item, response, spider_name, spider_key},
             result: {:ok, next} | {:error, term()}
  def parse_item({response, spider_name, spider_key}) do
    try do
      # get parsers
      parsers = Crawly.Utils.get_settings(:parsers, spider_name, nil)
      parsed_item = do_parse(parsers, spider_name, response)

      {:ok, {parsed_item, response, spider_name, spider_key}}
    catch
      error, reason ->
        Logger.warning(
          "Could not parse item, error: #{inspect(error)}, reason: #{inspect(reason)}"
        )

        Logger.warning(Exception.format(:error, error, __STACKTRACE__))

        {:error, reason}
    end
  end

  defp do_parse(nil, spider_name, response),
    do: spider_name.parse_item(response)

  defp do_parse(parsers, spider_name, response) when is_list(parsers) do
    case Crawly.Utils.pipe(parsers, %{}, %{
           spider_name: spider_name,
           response: response
         }) do
      {false, _} ->
        Logger.debug(
          "Dropped parse item from parser pipeline, url: #{response.request_url}, spider_name: #{inspect(spider_name)}"
        )

        throw(:dropped_parse_item)

      {parsed, _new_state} ->
        parsed
    end
  end

  @spec process_parsed_item({parsed_item, response, spider_name, spider_key}) ::
          result
        when spider_name: atom(),
             spider_key: spider_key(),
             response: HTTPoison.Response.t(),
             parsed_item: Crawly.ParsedItem.t(),
             result: {:ok, :done}
  defp process_parsed_item({parsed_item, response, _spider_name, spider_key}) do
    requests = Map.get(parsed_item, :requests) || []
    items = Map.get(parsed_item, :items) || []
    # Process all requests one by one
    Enum.each(
      requests,
      fn request ->
        request = Map.put(request, :prev_response, response)
        Crawly.RequestsStorage.store(spider_key, request)
      end
    )

    # Process all items one by one
    Enum.each(items, &Crawly.DataStorage.store(spider_key, &1))

    {:ok, :done}
  end

  ## Retry a request if max retries allows to do so
  defp maybe_retry_request(
         {spider_name, _crawl_id} = spider_key,
         %Crawly.Request{} = request
       ) do
    retries = request.retries

    retry_settings =
      Crawly.Utils.get_settings(:retry, spider_name, Keyword.new())

    ignored_middlewares = Keyword.get(retry_settings, :ignored_middlewares, [])
    max_retries = Keyword.get(retry_settings, :max_retries, 0)

    case retries <= max_retries do
      true ->
        Logger.debug("Request to #{request.url}, is scheduled for retry")

        middlewares = request.middlewares -- ignored_middlewares

        request = %Crawly.Request{
          request
          | middlewares: middlewares,
            retries: retries + 1
        }

        :ok = Crawly.RequestsStorage.store(spider_key, request)

      false ->
        Logger.error("Dropping request to #{request.url}, (max retries)")
        :ok
    end
  end
end
