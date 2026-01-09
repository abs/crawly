defmodule DataStorageWorkerTest do
  use ExUnit.Case, async: false

  setup do
    name = :test_crawler
    crawl_id = "123"
    {:ok, pid} = Crawly.DataStorage.start_worker(name, crawl_id)
    spider_key = {name, crawl_id}

    on_exit(fn ->
      :meck.unload()

      :ok =
        DynamicSupervisor.terminate_child(Crawly.DataStorage.WorkersSup, pid)
    end)

    {:ok, %{crawler: name, spider_key: spider_key}}
  end

  test "Can store data item", context do
    Crawly.DataStorage.store(context.spider_key, %{
      title: "test title",
      author: "me",
      time: "Now",
      url: "http://example.com"
    })

    {:stored_items, 1} = Crawly.DataStorage.stats(context.spider_key)
  end

  test "Dropped item are not stored", context do
    Crawly.DataStorage.store(context.spider_key, %{
      title: "test title",
      author: "me",
      time: "Now",
      url: "http://example.com"
    })

    Crawly.DataStorage.store(context.spider_key, %{
      title: "test title",
      author: "me",
      time: "Now",
      url: "http://example.com"
    })

    {:stored_items, 1} = Crawly.DataStorage.stats(context.spider_key)
  end

  test "Starting child worker twice", context do
    result = Crawly.DataStorage.start_worker(context.crawler, "123")
    assert result == {:error, :already_started}
  end

  test "Stats for not running spiders" do
    result = Crawly.DataStorage.stats({:unknown, "unknown"})
    assert result == {:error, :data_storage_worker_not_running}
  end

  test "Can inspect data storage worker state", context do
    result = Crawly.DataStorage.inspect(context.spider_key, :crawl_id)
    assert {:inspect, "123"} == result
  end
end
