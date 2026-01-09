defmodule Crawly.ManagerSup do
  # A supervisor module used to spawn Crawler trees
  @moduledoc false
  use Supervisor

  def start_link([spider_name, options]) do
    Supervisor.start_link(__MODULE__, [spider_name, options])
  end

  @impl true
  def init([spider_name, options]) do
    crawl_id = Keyword.get(options, :crawl_id)
    # Use a unique name per spider instance (spider_name + crawl_id)
    worker_sup_name = worker_supervisor_name(spider_name, crawl_id)

    children = [
      # This supervisor is used to spawn Worker processes
      {DynamicSupervisor, strategy: :one_for_one, name: worker_sup_name},

      # Starts spider manager process
      {Crawly.Manager, [spider_name, options]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def worker_supervisor_name(spider_name, crawl_id) do
    :"#{spider_name}_#{crawl_id}"
  end
end
