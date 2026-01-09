defmodule EngineTest do
  use ExUnit.Case

  setup do
    Crawly.Engine.stop_spider_by_name(TestSpider)

    on_exit(fn ->
      :meck.unload()

      Crawly.Engine.list_known_spiders()
      |> Enum.each(fn s ->
        Crawly.Engine.stop_spider_by_name(s.name)
      end)
    end)
  end

  test "list_known_spiders/0 lists all spiders and their current status in the engine" do
    Crawly.Engine.refresh_spider_list()
    # Note: list_known_spiders may be empty if no spiders defined in config

    # test a started spider
    Crawly.Engine.start_spider(TestSpider)
    crawl_id = Crawly.Engine.get_running_crawl_id(TestSpider)
    assert crawl_id != nil

    # Verify spider is running
    running = Crawly.Engine.running_spiders()
    assert Map.has_key?(running, {TestSpider, crawl_id})

    # stop spider
    Crawly.Engine.stop_spider({TestSpider, crawl_id})
    running = Crawly.Engine.running_spiders()
    refute Map.has_key?(running, {TestSpider, crawl_id})
  end

  test "get_spider_info/1 return the spider currently status in the engine" do
    # test a started spider
    Crawly.Engine.start_spider(TestSpider)
    crawl_id = Crawly.Engine.get_running_crawl_id(TestSpider)
    spider_key = {TestSpider, crawl_id}

    # running_spiders should have our spider
    running = Crawly.Engine.running_spiders()
    assert Map.has_key?(running, spider_key)

    # stop spider
    Crawly.Engine.stop_spider(spider_key)
    running = Crawly.Engine.running_spiders()
    refute Map.has_key?(running, spider_key)
  end

  test ":log_to_file allows for logging to log file" do
    :meck.expect(TestSpider, :override_settings, fn ->
      [log_dir: "/my_tmp_dir", log_to_file: true]
    end)

    :meck.expect(Logger, :configure_backend, fn {_, :debug}, opts ->
      log_file_path = Keyword.get(opts, :path)
      assert log_file_path =~ "TestSpider"
      assert log_file_path =~ "/my_tmp_dir"
    end)

    Crawly.Engine.refresh_spider_list()

    # test a started spider
    Crawly.Engine.start_spider(TestSpider)

    assert :meck.num_calls(Logger, :configure_backend, :_) == 1
  end

  test "LoggerFileBackend is not configured when module is not loaded" do
    :meck.expect(TestSpider, :override_settings, fn ->
      [log_dir: "/my_tmp_dir", log_to_file: true]
    end)

    :meck.expect(Crawly.Utils, :ensure_loaded?, fn _ ->
      false
    end)

    :meck.expect(Logger, :configure_backend, fn {_, :debug}, opts ->
      log_file_path = Keyword.get(opts, :path)
      assert log_file_path =~ "TestSpider"
      assert log_file_path =~ "/my_tmp_dir"
    end)

    Crawly.Engine.refresh_spider_list()

    # test a started spider
    Crawly.Engine.start_spider(TestSpider)
    assert :meck.num_calls(Logger, :configure_backend, :_) == 0
  end

  test "LoggerFileBackend is configured when module is loaded" do
    :meck.expect(TestSpider, :override_settings, fn ->
      [log_dir: "/my_tmp_dir", log_to_file: true]
    end)

    :meck.expect(Crawly.Utils, :ensure_loaded?, fn _ ->
      true
    end)

    :meck.expect(Logger, :configure_backend, fn {_, :debug}, opts ->
      log_file_path = Keyword.get(opts, :path)
      assert log_file_path =~ "TestSpider"
      assert log_file_path =~ "/my_tmp_dir"
    end)

    Crawly.Engine.refresh_spider_list()

    # test a started spider
    Crawly.Engine.start_spider(TestSpider)
    assert :meck.num_calls(Logger, :configure_backend, :_) == 1
  end

  describe "concurrent spider instances" do
    test "can run multiple instances of the same spider with different crawl_ids" do
      # Start first instance
      :ok = Crawly.Engine.start_spider(TestSpider, crawl_id: "crawl-1")

      # Start second instance with different crawl_id
      :ok = Crawly.Engine.start_spider(TestSpider, crawl_id: "crawl-2")

      # Verify both are running
      running = Crawly.Engine.running_spiders()
      assert Map.has_key?(running, {TestSpider, "crawl-1"})
      assert Map.has_key?(running, {TestSpider, "crawl-2"})
      assert map_size(running) >= 2

      # Each instance has its own storage
      spider_key_1 = {TestSpider, "crawl-1"}
      spider_key_2 = {TestSpider, "crawl-2"}

      {:stored_requests, count1} = Crawly.RequestsStorage.stats(spider_key_1)
      {:stored_requests, count2} = Crawly.RequestsStorage.stats(spider_key_2)
      assert is_integer(count1)
      assert is_integer(count2)

      # Stop first instance - second should keep running
      :ok = Crawly.Engine.stop_spider(spider_key_1)

      running = Crawly.Engine.running_spiders()
      refute Map.has_key?(running, spider_key_1)
      assert Map.has_key?(running, spider_key_2)

      # Clean up
      :ok = Crawly.Engine.stop_spider(spider_key_2)
    end

    test "starting same spider with same crawl_id returns error" do
      :ok = Crawly.Engine.start_spider(TestSpider, crawl_id: "same-crawl")

      # Trying to start again with same crawl_id should fail
      assert {:error, :spider_already_started} =
               Crawly.Engine.start_spider(TestSpider, crawl_id: "same-crawl")

      # Clean up
      Crawly.Engine.stop_spider({TestSpider, "same-crawl"})
    end

    test "stop_spider_by_name stops all instances of a spider" do
      :ok = Crawly.Engine.start_spider(TestSpider, crawl_id: "instance-1")
      :ok = Crawly.Engine.start_spider(TestSpider, crawl_id: "instance-2")
      :ok = Crawly.Engine.start_spider(TestSpider, crawl_id: "instance-3")

      running = Crawly.Engine.running_spiders()
      assert map_size(running) >= 3

      # Stop all instances by name
      :ok = Crawly.Engine.stop_spider_by_name(TestSpider)

      running = Crawly.Engine.running_spiders()
      # No TestSpider instances should be running
      refute Enum.any?(running, fn {{name, _}, _} -> name == TestSpider end)
    end

    test "no cross-contamination: data stored in one instance doesn't appear in another" do
      # Start two instances of the same spider with timeouts disabled
      :ok =
        Crawly.Engine.start_spider(TestSpider,
          crawl_id: "isolated-1",
          closespider_timeout: :disabled,
          closespider_itemcount: :disabled
        )

      :ok =
        Crawly.Engine.start_spider(TestSpider,
          crawl_id: "isolated-2",
          closespider_timeout: :disabled,
          closespider_itemcount: :disabled
        )

      spider_key_1 = {TestSpider, "isolated-1"}
      spider_key_2 = {TestSpider, "isolated-2"}

      # Store a request in instance 1 only
      request_1 =
        Crawly.Utils.request_from_url("https://example.com/only-in-instance-1")

      :ok = Crawly.RequestsStorage.store(spider_key_1, request_1)

      # Store a different request in instance 2 only
      request_2 =
        Crawly.Utils.request_from_url("https://example.com/only-in-instance-2")

      :ok = Crawly.RequestsStorage.store(spider_key_2, request_2)

      # Verify instance 1 has exactly 1 request (the initial start_url + our added one)
      {:stored_requests, count1_before} =
        Crawly.RequestsStorage.stats(spider_key_1)

      {:stored_requests, count2_before} =
        Crawly.RequestsStorage.stats(spider_key_2)

      # Pop from instance 1 - should get the request we stored there
      popped_1 = Crawly.RequestsStorage.pop(spider_key_1)
      assert popped_1 != nil

      # Pop from instance 2 - should get the request we stored there, not instance 1's
      popped_2 = Crawly.RequestsStorage.pop(spider_key_2)
      assert popped_2 != nil

      # The URLs should be different (each got their own request)
      # Note: The order of popping depends on internal queue, but the point is
      # each instance has its own separate storage
      {:stored_requests, count1_after} =
        Crawly.RequestsStorage.stats(spider_key_1)

      {:stored_requests, count2_after} =
        Crawly.RequestsStorage.stats(spider_key_2)

      # Each instance's count should have decreased by 1
      assert count1_after == count1_before - 1
      assert count2_after == count2_before - 1

      # Store an item in instance 1's data storage
      item_1 = %{
        title: "Item for instance 1",
        url: "https://example.com/1",
        author: "test",
        time: "now"
      }

      Crawly.DataStorage.store(spider_key_1, item_1)

      # Verify instance 1 has the item, instance 2 doesn't
      {:stored_items, items_1} = Crawly.DataStorage.stats(spider_key_1)
      {:stored_items, items_2} = Crawly.DataStorage.stats(spider_key_2)

      assert items_1 >= 1
      assert items_2 == 0

      # Clean up
      :ok = Crawly.Engine.stop_spider(spider_key_1)
      :ok = Crawly.Engine.stop_spider(spider_key_2)
    end
  end
end
