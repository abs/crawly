# ExUnit.start()
ExUnit.start(exclude: [:skip])

# Mock Gollum globally to avoid network calls in tests
:meck.new(Gollum, [:passthrough])
:meck.expect(Gollum, :crawlable?, fn _, _ -> :crawlable end)
