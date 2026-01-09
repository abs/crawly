defmodule Crawly.Pipelines.Experimental.SendToUI do
  @moduledoc false
  @behaviour Crawly.Pipeline

  require Logger

  @impl Crawly.Pipeline
  def run(item, state, opts \\ []) do
    job_tag =
      Map.get_lazy(state, :job_tag, fn ->
        # Use crawl_id from state directly (already available in pipeline state)
        state.crawl_id
      end)

    spider_name = state.spider_name |> Atom.to_string()

    case Keyword.get(opts, :ui_node) do
      nil ->
        Logger.debug(
          "No ui node is set. It's required to set a UI node to use " <>
            "this pipeline. Ignoring the pipeline."
        )

      ui_node ->
        :rpc.cast(ui_node, CrawlyUI, :store_item, [
          spider_name,
          item,
          job_tag,
          Node.self() |> to_string()
        ])
    end

    {item, Map.put(state, :job_tag, job_tag)}
  end
end
