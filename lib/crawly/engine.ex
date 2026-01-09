defmodule Crawly.Engine do
  @moduledoc """
  Crawly Engine - process responsible for starting and stopping spiders.

  Stores all currently running spiders.
  """
  require Logger

  use GenServer

  @type t :: %__MODULE__{
          started_spiders: started_spiders(),
          known_spiders: [Crawly.spider()]
        }

  @type spider_key() :: {Crawly.spider(), crawl_id :: binary()}
  @type started_spiders() :: %{optional(spider_key()) => identifier()}

  @type spider_info() :: %{
          name: Crawly.spider(),
          status: :stopped | :started,
          pid: identifier() | nil
        }

  defstruct(started_spiders: %{}, known_spiders: [])

  @doc """
  Starts a spider. All options passed in the second argument will be passed along to the spider's `init/1` callback.

  ### Reserved Options
  - `:crawl_id` (binary). Optional, automatically generated if not set.
  - `:closespider_itemcount` (integer | disabled). Optional, overrides the close
    spider item count on startup.
  - `:closespider_timeout` (integer | disabled). Optional, overrides the close
    spider timeout on startup.
  - `:concurrent_requests_per_domain` (integer). Optional, overrides the number of
     workers for a given spider

  ### Backward compatibility
  If the 2nd positional argument is a binary, it will be set as the `:crawl_id`. Deprecated, will be removed in the future.
  """
  @type crawl_id_opt :: {:crawl_id, binary()} | GenServer.option()
  @spec start_spider(Crawly.spider(), opts) :: result
        when opts: [crawl_id_opt],
             result:
               :ok
               | {:error, :spider_already_started}
               | {:error, :atom}
  def start_spider(spider_name, opts \\ [])

  def start_spider(spider_name, crawl_id) when is_binary(crawl_id) do
    Logger.warning(
      "Deprecation Warning: Setting the crawl_id as second positional argument is deprecated. Please use the :crawl_id option instead. Refer to docs for more info (https://hexdocs.pm/crawly/Crawly.Engine.html#start_spider/2) "
    )

    start_spider(spider_name, crawl_id: crawl_id)
  end

  def start_spider(spider_name, opts) when is_list(opts) do
    opts =
      Enum.into(opts, %{})
      |> Map.put_new_lazy(:crawl_id, &UUID.uuid1/0)

    # Filter all logs related to a given spider
    case {Crawly.Utils.get_settings(:log_to_file, spider_name),
          Crawly.Utils.ensure_loaded?(LoggerFileBackend)} do
      {true, true} ->
        configure_spider_logs(spider_name, opts[:crawl_id])

      {true, false} ->
        Logger.error(
          ":logger_file_backend https://github.com/onkel-dirtus/logger_file_backend#loggerfilebackend must be installed as a peer dependency if log_to_file config is set to true"
        )

      _ ->
        false
    end

    GenServer.call(
      __MODULE__,
      {:start_spider, spider_name, opts[:crawl_id], Map.to_list(opts)}
    )
  end

  @spec get_manager(spider_key()) :: pid() | {:error, :spider_not_found}
  def get_manager({spider_name, crawl_id}) do
    case Map.fetch(running_spiders(), {spider_name, crawl_id}) do
      :error ->
        {:error, :spider_not_found}

      {:ok, {pid_sup, _job_tag}} ->
        Supervisor.which_children(pid_sup)
        |> Enum.find(&({Crawly.Manager, _, :worker, [Crawly.Manager]} = &1))
        |> case do
          nil ->
            {:error, :spider_not_found}

          {_, pid, :worker, _} ->
            pid
        end
    end
  end

  @spec stop_spider(spider_key(), reason) :: result
        when reason: :itemcount_limit | :itemcount_timeout | atom(),
             result:
               :ok | {:error, :spider_not_running} | {:error, :spider_not_found}
  def stop_spider(spider_key, reason \\ :ignore)

  def stop_spider({spider_name, crawl_id}, reason) do
    GenServer.call(__MODULE__, {:stop_spider, {spider_name, crawl_id}, reason})
  end

  @doc """
  Stop all running instances of a spider module.
  Useful for test cleanup when you don't have the crawl_id.
  """
  @spec stop_spider_by_name(Crawly.spider(), reason :: atom()) :: :ok
  def stop_spider_by_name(spider_name, reason \\ :ignore)
      when is_atom(spider_name) do
    running = running_spiders()

    running
    |> Enum.filter(fn {{name, _crawl_id}, _} -> name == spider_name end)
    |> Enum.each(fn {{name, crawl_id}, _} ->
      stop_spider({name, crawl_id}, reason)
    end)

    :ok
  end

  @doc """
  Get the first running instance's crawl_id for a spider module.
  Useful for tests when you know there's only one instance.
  Returns nil if no instances are running.
  """
  @spec get_running_crawl_id(Crawly.spider()) :: binary() | nil
  def get_running_crawl_id(spider_name) when is_atom(spider_name) do
    running = running_spiders()

    case Enum.find(running, fn {{name, _}, _} -> name == spider_name end) do
      {{_, crawl_id}, _} -> crawl_id
      nil -> nil
    end
  end

  @spec list_known_spiders() :: [spider_info()]
  def list_known_spiders() do
    GenServer.call(__MODULE__, :list_known_spiders)
  end

  @spec running_spiders() :: started_spiders()
  def running_spiders() do
    GenServer.call(__MODULE__, :running_spiders)
  end

  @spec get_spider_info(spider_key()) :: spider_info() | nil
  def get_spider_info(spider_key) do
    GenServer.call(__MODULE__, {:get_spider, spider_key})
  end

  def refresh_spider_list() do
    GenServer.cast(__MODULE__, :refresh_spider_list)
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec get_crawl_id(spider_key()) ::
          {:error, :spider_not_running} | {:ok, binary()}
  def get_crawl_id(spider_key) do
    GenServer.call(__MODULE__, {:get_crawl_id, spider_key})
  end

  @spec init(any) :: {:ok, t()}
  def init(_args) do
    {:ok, %Crawly.Engine{}, {:continue, :get_known_spiders}}
  end

  def handle_continue(:get_known_spiders, state) do
    spiders = get_updated_known_spider_list()

    {:noreply, %{state | known_spiders: spiders}}
  end

  def handle_call({:get_manager, spider_key}, _, state) do
    pid =
      case Map.get(state.started_spiders, spider_key) do
        nil ->
          {:error, :spider_not_found}

        {pid, _crawl_id} ->
          pid
      end

    {:reply, pid, state}
  end

  def handle_call({:get_crawl_id, spider_key}, _from, state) do
    msg =
      case Map.get(state.started_spiders, spider_key) do
        nil ->
          {:error, :spider_not_running}

        {_pid, crawl_id} ->
          {:ok, crawl_id}
      end

    {:reply, msg, state}
  end

  def handle_call(:running_spiders, _from, state) do
    {:reply, state.started_spiders, state}
  end

  def handle_call(:list_known_spiders, _from, state) do
    return = Enum.map(state.known_spiders, &format_spider_info(&1, state))
    {:reply, return, state}
  end

  def handle_call(
        {:start_spider, spider_name, crawl_id, options},
        _form,
        %Crawly.Engine{} = state
      ) do
    spider_key = {spider_name, crawl_id}

    result =
      case Map.get(state.started_spiders, spider_key) do
        nil ->
          Crawly.EngineSup.start_spider(spider_name, options)

        _ ->
          {:error, :spider_already_started}
      end

    {msg, new_started_spiders} =
      case result do
        {:ok, pid} ->
          # Insert information about the job into storage
          Crawly.Models.Job.new(crawl_id, spider_name)

          {:ok, Map.put(state.started_spiders, spider_key, {pid, crawl_id})}

        {:error, _} = err ->
          {err, state.started_spiders}
      end

    {:reply, msg, %Crawly.Engine{state | started_spiders: new_started_spiders}}
  end

  def handle_call(
        {:stop_spider, {spider_name, crawl_id} = spider_key, reason},
        _form,
        %Crawly.Engine{} = state
      ) do
    {msg, new_started_spiders} =
      case Map.pop(state.started_spiders, spider_key) do
        {nil, _} ->
          {{:error, :spider_not_running}, state.started_spiders}

        {{pid, ^crawl_id}, new_started_spiders} ->
          case Crawly.Utils.get_settings(
                 :on_spider_closed_callback,
                 spider_name
               ) do
            nil -> :ignore
            fun -> apply(fun, [spider_name, crawl_id, reason])
          end

          # Update jobs log information
          {:stored_items, num} = Crawly.DataStorage.stats(spider_key)
          Crawly.Models.Job.update(crawl_id, num, reason)

          Crawly.EngineSup.stop_spider(pid)

          {:ok, new_started_spiders}
      end

    {:reply, msg, %Crawly.Engine{state | started_spiders: new_started_spiders}}
  end

  def handle_call(
        {:get_spider, {spider_name, _crawl_id} = spider_key},
        _from,
        state
      ) do
    return =
      if Enum.member?(state.known_spiders, spider_name) do
        format_spider_info(spider_key, state)
      end

    {:reply, return, state}
  end

  def handle_cast(:refresh_spider_list, %Crawly.Engine{} = state) do
    updated = get_updated_known_spider_list(state.known_spiders)
    {:noreply, %Crawly.Engine{state | known_spiders: updated}}
  end

  # this function generates a spider_info map for each spider known
  # When given just a spider module name, check if any instances are running
  defp format_spider_info(spider_name, state) when is_atom(spider_name) do
    # Find any running instance of this spider module
    running_instance =
      Enum.find(state.started_spiders, fn
        {{name, _crawl_id}, _} -> name == spider_name
        _ -> false
      end)

    case running_instance do
      nil ->
        %{name: spider_name, status: :stopped, pid: nil}

      {{^spider_name, _crawl_id}, {pid, _}} ->
        %{name: spider_name, status: :started, pid: pid}
    end
  end

  # When given a tuple key, look up that specific instance
  defp format_spider_info({spider_name, _crawl_id} = spider_key, state) do
    entry = Map.get(state.started_spiders, spider_key)

    %{
      name: spider_name,
      status: if(is_nil(entry), do: :stopped, else: :started),
      pid: if(entry, do: elem(entry, 0), else: nil)
    }
  end

  defp get_updated_known_spider_list(known \\ []) do
    new = Crawly.Utils.list_spiders()

    (known ++ new)
    |> Enum.dedup_by(& &1)
  end

  defp configure_spider_logs(spider_name, crawl_id) do
    log_file_path = Crawly.Utils.spider_log_path(spider_name, crawl_id)
    Logger.add_backend({LoggerFileBackend, :debug})

    Logger.configure_backend({LoggerFileBackend, :debug},
      path: Crawly.Utils.spider_log_path(spider_name, crawl_id),
      level: :debug,
      metadata_filter: [crawl_id: crawl_id]
    )

    Logger.debug("Writing logs to #{log_file_path}")
  end
end
