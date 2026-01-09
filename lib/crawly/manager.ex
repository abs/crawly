defmodule Crawly.Manager do
  @moduledoc """
  Crawler manager module

  This module is responsible for spawning all processes related to
  a given Crawler.

  The manager spawns the following processes tree.
  ┌────────────────┐        ┌───────────────────┐
  │ Crawly.Manager ├────────> Crawly.ManagerSup │
  └────────────────┘        └─────────┬─────────┘
           │                          |
           │                          |
           ┌──────────────────────────┤
           │                          │
           │                          │
  ┌────────▼───────┐        ┌─────────▼───────┐
  │    Worker1     │        │    Worker2      │
  └────────┬───────┘        └────────┬────────┘
           │                         │
           │                         │
           │                         │
           │                         │
  ┌────────▼─────────┐    ┌──────────▼───────────┐
  │Crawly.DataStorage│    │Crawly.RequestsStorage│
  └──────────────────┘    └──────────────────────┘
  """
  require Logger

  @timeout 60_000
  @start_request_split_size 50

  use GenServer

  alias Crawly.{Engine, Utils}

  @type spider_key() :: {Crawly.spider(), crawl_id :: binary()}

  @spec add_workers(spider_key(), non_neg_integer()) ::
          :ok | {:error, :spider_non_exist}
  def add_workers(spider_key, num_of_workers) do
    case Engine.get_manager(spider_key) do
      {:error, reason} ->
        {:error, reason}

      pid ->
        GenServer.cast(pid, {:add_workers, num_of_workers})
    end
  end

  def start_link([spider_name, options]) do
    Logger.debug("Starting the manager for #{inspect(spider_name)}")
    GenServer.start_link(__MODULE__, [spider_name, options])
  end

  @impl true
  def init([spider_name, options]) do
    crawl_id = Keyword.get(options, :crawl_id)
    spider_key = {spider_name, crawl_id}

    # Store runtime options for access via get_settings
    :persistent_term.put({:crawly_spider_options, spider_name}, options)

    Logger.metadata(spider_name: spider_name, crawl_id: crawl_id)

    itemcount_limit =
      Keyword.get(
        options,
        :closespider_itemcount,
        get_default_limit(:closespider_itemcount, spider_name)
      )

    closespider_timeout_limit =
      Keyword.get(
        options,
        :closespider_timeout,
        get_default_limit(:closespider_timeout, spider_name)
      )

    # Start DataStorage worker
    {:ok, data_storage_pid} =
      Crawly.DataStorage.start_worker(spider_name, crawl_id)

    Process.link(data_storage_pid)

    # Start RequestsWorker for a given spider
    {:ok, request_storage_pid} =
      Crawly.RequestsStorage.start_worker(spider_name, crawl_id)

    Process.link(request_storage_pid)

    # Start workers
    num_workers =
      Keyword.get(
        options,
        :concurrent_requests_per_domain,
        Utils.get_settings(:concurrent_requests_per_domain, spider_name, 4)
      )

    worker_sup_name =
      Crawly.ManagerSup.worker_supervisor_name(spider_name, crawl_id)

    worker_pids =
      Enum.map(1..num_workers, fn _x ->
        DynamicSupervisor.start_child(
          worker_sup_name,
          {Crawly.Worker, [spider_name: spider_name, crawl_id: crawl_id]}
        )
      end)

    # Schedule basic service operations for given spider manager
    timeout =
      Utils.get_settings(:manager_operations_timeout, spider_name, @timeout)

    tref = Process.send_after(self(), :operations, timeout)

    Logger.debug(
      "Started #{Enum.count(worker_pids)} workers for #{inspect(spider_name)}"
    )

    {:ok,
     %{
       name: spider_name,
       crawl_id: crawl_id,
       spider_key: spider_key,
       worker_sup_name: worker_sup_name,
       itemcount_limit: itemcount_limit,
       closespider_timeout_limit: closespider_timeout_limit,
       tref: tref,
       prev_scraped_cnt: 0,
       workers: worker_pids
     }, {:continue, {:startup, options}}}
  end

  @impl true
  def handle_continue({:startup, options}, state) do
    # Add start requests to the requests storage
    init = state.name.init(options)

    start_requests_from_req = Keyword.get(init, :start_requests, [])

    start_requests_from_urls =
      init
      |> Keyword.get(:start_urls, [])
      |> Crawly.Utils.requests_from_urls()

    start_requests = start_requests_from_req ++ start_requests_from_urls

    # Split start requests, so it's possible to initialize a part of them in async
    # manner
    {start_reqs, async_start_reqs} =
      Enum.split(start_requests, @start_request_split_size)

    :ok = Crawly.RequestsStorage.store(state.spider_key, start_reqs)

    spider_key = state.spider_key

    Task.start(fn ->
      Crawly.RequestsStorage.store(spider_key, async_start_reqs)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_workers, num_of_workers}, state) do
    Logger.info("Adding #{num_of_workers} workers for #{inspect(state.name)}")

    Enum.each(1..num_of_workers, fn _ ->
      DynamicSupervisor.start_child(
        state.worker_sup_name,
        {Crawly.Worker, [spider_name: state.name, crawl_id: state.crawl_id]}
      )
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:operations, state) do
    Process.cancel_timer(state.tref)

    # Close spider if required items count was reached.
    {:stored_items, items_count} = Crawly.DataStorage.stats(state.spider_key)

    {:stored_requests, requests_count} =
      Crawly.RequestsStorage.stats(state.spider_key)

    delta = items_count - state.prev_scraped_cnt

    Logger.info("Current crawl speed is: #{delta} items/min")
    Logger.info("Current requests count is: #{requests_count}")

    stop_spider_by_requests_count_and_delta(
      state.spider_key,
      requests_count,
      delta
    )

    maybe_stop_spider_by_itemcount_limit(
      state.spider_key,
      items_count,
      state.itemcount_limit
    )

    # Close spider in case if it's not scraping items fast enough
    maybe_stop_spider_by_timeout(
      state.spider_key,
      delta,
      state.closespider_timeout_limit
    )

    tref =
      Process.send_after(
        self(),
        :operations,
        Utils.get_settings(:manager_operations_timeout, state.name, @timeout)
      )

    {:noreply, %{state | tref: tref, prev_scraped_cnt: items_count}}
  end

  defp stop_spider_by_requests_count_and_delta(
         spider_key,
         requests_count,
         delta
       )
       when requests_count == 0 and delta == 0 do
    Logger.info("Stopping #{inspect(spider_key)}, all requests handled")

    Crawly.Engine.stop_spider(spider_key, :spider_finished)
  end

  defp stop_spider_by_requests_count_and_delta(_, _, _), do: :ok

  defp maybe_stop_spider_by_itemcount_limit(
         spider_key,
         current,
         limit
       )
       when current >= limit do
    Logger.info(
      "Stopping #{inspect(spider_key)}, closespider_itemcount achieved"
    )

    Crawly.Engine.stop_spider(spider_key, :itemcount_limit)
  end

  defp maybe_stop_spider_by_itemcount_limit(_, _, _), do: :ok

  defp maybe_stop_spider_by_timeout(spider_key, current, limit)
       when current <= limit and is_integer(limit) do
    Logger.info("Stopping #{inspect(spider_key)}, itemcount timeout achieved")

    Crawly.Engine.stop_spider(spider_key, :itemcount_timeout)
  end

  defp maybe_stop_spider_by_timeout(_, _, _), do: :ok

  defp maybe_convert_to_integer(value) when is_atom(value), do: value

  defp maybe_convert_to_integer(value) when is_binary(value),
    do: String.to_integer(value)

  defp maybe_convert_to_integer(value) when is_integer(value), do: value

  # Get a closespider_itemcount or closespider_timeout_limit from config or spider
  # settings.
  defp get_default_limit(limit_name, spider_name) do
    limit_name
    |> Utils.get_settings(spider_name)
    |> maybe_convert_to_integer()
  end
end
